//
//  machController.swift
//  Selfde
//

import Darwin.Mach
import Foundation

public struct ControllerInterrupter {
    private unowned let controller: Controller

    public func sendInterrupt(_ function: @noescape () -> ()) {
        controller.interrupt(function)
    }
}

/// Implements the Selfde controller for a process running on a Mach kernel.
public class Controller {
    private var state: SelfdeMachControllerState
    private var hasInterrupt: Bool = false
    private var utilityThreadPort: mach_port_t // Can be used for things like listening for remote debugging commands.
    private var utilityThread: Foundation.Thread?
    private struct BreakpointState {
        let machineState: MachineBreakpointState
        let landingAddress: OpaquePointer
        var counter: Int
    }
    private var breakpoints: [OpaquePointer: BreakpointState] = [:]
    private var breakpointLandingAddresses: [OpaquePointer: OpaquePointer] = [:]
    private struct AllocationState {
        let address: mach_vm_address_t
        let size: mach_vm_size_t
    }
    private var allocations: [OpaquePointer: AllocationState] = [:]

    init() throws {
        // Create the synchronisation primitives.
        var condition = pthread_cond_t()
        try handlePosixError(pthread_cond_init(&condition, nil))
        var mutex = pthread_mutex_t()
        try handlePosixError(pthread_mutex_init(&mutex, nil))

        let thread = mach_thread_self()
        state = SelfdeMachControllerState(task: getMachTaskSelf(), controllerThread: thread, msgServerThread: thread, exceptionPort: 0, synchronisationCondition: condition, synchronisationMutex: mutex, caughtException: SelfdeCaughtMachException(thread: 0, exceptionType: 0, exceptionData: nil, exceptionDataSize: 0), hasCaughtException: false)
        utilityThreadPort = thread
    }

    deinit {
        if state.msgServerThread != state.controllerThread {
            if thread_terminate(state.msgServerThread) != KERN_SUCCESS {
                return
            }
        }
        if let thread = utilityThread where !thread.isFinished {
            if thread_terminate(utilityThreadPort) != KERN_SUCCESS {
                return
            }
            utilityThread = nil
        }
        pthread_mutex_destroy(&state.synchronisationMutex)
        pthread_cond_destroy(&state.synchronisationCondition)
    }

    /// Starts a thread that listens for exceptions like breakpoints for
    /// the given threads.
    public func initializeExceptionHandlingForThreads(_ threads: [Thread]) throws {
        // Create the exception port and make sure it's connected to the threads we're interested in.
        try handleError(selfdeCreateExceptionPort(state.task, &state.exceptionPort))
        for thread in threads {
            try handleError(selfdeSetExceptionPortForThread(thread.thread, state.exceptionPort))
        }

        // Run the thread that will listen for the exceptions.
        try handleError(selfdeStartExceptionThread(&state))
    }

    private func interrupt(_ function: @noescape () -> ()) {
        pthread_mutex_lock(&state.synchronisationMutex)
        hasInterrupt = true
        function()
        pthread_cond_signal(&state.synchronisationCondition)
        pthread_mutex_unlock(&state.synchronisationMutex)
    }

    public func runUtilityThread(_ function: (ControllerInterrupter) -> ()) {
        final class UtilityThread: Foundation.Thread {
            unowned let controller: Controller
            let function: (ControllerInterrupter) -> ()

            init(controller: Controller, function: (ControllerInterrupter) -> ()) {
                self.controller = controller
                self.function = function
                super.init()
            }

            override func main() {
                controller.interrupt {
                    controller.utilityThreadPort = mach_thread_self()
                }
                function(ControllerInterrupter(controller: controller))
            }
        }
        let thread = UtilityThread(controller: self, function: function)
        utilityThread = thread
        assert(hasInterrupt == false)
        thread.start()
        pthread_mutex_lock(&state.synchronisationMutex)
        while !hasInterrupt {
            pthread_cond_wait(&state.synchronisationCondition, &state.synchronisationMutex)
        }
        hasInterrupt = false
        pthread_mutex_unlock(&state.synchronisationMutex)
    }

    public func waitForEvent(interruptHandler: (() -> ())? = nil) throws -> ControllerEvent {
        pthread_mutex_lock(&state.synchronisationMutex)
        while !state.hasCaughtException && !hasInterrupt {
            pthread_cond_wait(&state.synchronisationCondition, &state.synchronisationMutex)
        }
        guard state.hasCaughtException else {
            assert(hasInterrupt)
            interruptHandler?()
            hasInterrupt = false
            pthread_mutex_unlock(&state.synchronisationMutex)
            return .interrupted
        }
        let data = UnsafeMutableBufferPointer<mach_exception_data_type_t>(start: state.caughtException.exceptionData, count: Int(state.caughtException.exceptionDataSize))
        let result = Exception(thread: Thread(state.caughtException.thread), type: state.caughtException.exceptionType, data: Array(data.map { UInt($0) }))
        state.hasCaughtException = false
        hasInterrupt = false
        free(state.caughtException.exceptionData)
        pthread_mutex_unlock(&state.synchronisationMutex)
        try handleException(result)
        return .caughtException(result)
    }

    private func handleException(_ exception: Exception) throws {
        guard exception.isBreakpoint else {
            return
        }
        // We want to move the IP back to the breakpoint's address when we hit a breakpoint.
        let IP = try exception.thread.getInstructionPointer()
        guard let address = breakpointLandingAddresses[IP] else {
            // We could have simply stepped.
            return
        }
        try exception.thread.setInstructionPointer(address)
    }

    public func getSharedLibraryInfoAddress() throws -> OpaquePointer {
        var dyldInfo = task_dyld_info()
        var count = mach_msg_type_number_t(sizeof(task_dyld_info) / sizeof(Int32))
        let error = withUnsafeMutablePointer(&dyldInfo) {
            task_info(self.state.task, task_flavor_t(TASK_DYLD_INFO), UnsafeMutablePointer<integer_t>($0), &count)
        }
        try handleError(error)
        return OpaquePointer(bitPattern: UInt(dyldInfo.all_image_info_addr))!
    }

    public func suspendThreads() throws {
        for thread in try getThreads() {
            try thread.suspend()
        }
    }

    public func resumeThreads() throws {
        for thread in try getThreads() {
            try thread.resume()
        }
    }

    public func getThreads() throws -> [Thread] {
        var threads = thread_act_port_array_t(nil)
        var count = mach_msg_type_number_t(0)
        try handleError(task_threads(state.task, &threads, &count))
        var result = [Thread]()
        for i in 0..<count {
            let thread = threads?[Int(i)]
            if thread == state.controllerThread || thread == state.msgServerThread || thread == utilityThreadPort {
                continue;
            }
            result.append(Thread(thread!))
        }
        return result
    }

    /// Gives the given memory ALL protections.
    private func memoryProtectAll(_ address: OpaquePointer, size: vm_size_t) throws {
        let addr = vm_address_t(unsafeBitCast(address, to: UInt.self))
        try handleError(vm_protect(state.task, addr, size, boolean_t(0), getVMProtAll()))
    }

    public func installBreakpoint(_ address: OpaquePointer) throws -> Breakpoint {
        if let index = breakpoints.index(forKey: address) {
            var bp = breakpoints[index].1
            bp.counter += 1
            breakpoints.updateValue(bp, forKey: address)
            return Breakpoint(address: address)
        }
        // Make sure we can write to the address.
        try memoryProtectAll(address, size: MachineBreakpointState.numberOfBytesToPatch)
        let (machineState, landingAddress) = MachineBreakpointState.create(address)
        breakpoints[address] = BreakpointState(machineState: machineState, landingAddress: landingAddress, counter: 1)
        breakpointLandingAddresses[landingAddress] = address
        return Breakpoint(address: address)
    }

    private func restoreBreakpointsOriginalInstruction(_ breakpoint: (address: OpaquePointer, BreakpointState)) {
        breakpoint.1.machineState.restoreOriginalInstruction(breakpoint.address)
    }

    public func removeBreakpoint(_ breakpoint: Breakpoint) throws {
        guard let index = breakpoints.index(forKey: breakpoint.address) else {
            throw ControllerError.invalidBreakpoint
        }
        let keyValue = breakpoints[index]
        var bp = keyValue.1
        bp.counter -= 1
        guard bp.counter < 1 else {
            breakpoints.updateValue(bp, forKey: breakpoint.address)
            return
        }
		restoreBreakpointsOriginalInstruction((address: keyValue.key, keyValue.value))
        breakpoints.remove(at: index)
        guard let address = breakpointLandingAddresses.removeValue(forKey: bp.landingAddress) else {
            assertionFailure()
            return
        }
        assert(address == breakpoint.address)
    }

    public func allocate(_ size: Int, permissions: MemoryPermissions) throws -> OpaquePointer {
        var address = mach_vm_address_t()
        let allocationSize = mach_vm_size_t(size)
        try handleError(mach_vm_allocate(state.task, &address, allocationSize, 1))
        var protection: vm_prot_t = 0
        if permissions.contains(.Read) {
            protection |= getVMProtRead()
        }
        if permissions.contains(.Write) {
            protection |= getVMProtWrite()
        }
        if permissions.contains(.Execute) {
            protection |= getVMProtExecute()
        }
        do {
            try handleError(mach_vm_protect(state.task, address, allocationSize, 0, protection))
        } catch {
            mach_vm_deallocate(state.task, address, allocationSize)
            throw error
        }
        let result = OpaquePointer(bitPattern: UInt(address))
        allocations[result!] = AllocationState(address: address, size: allocationSize)
        return result!
    }

    public func deallocate(_ address: OpaquePointer) throws {
        guard let allocation = allocations[address] else {
            throw ControllerError.invalidAllocation
        }
        try handleError(mach_vm_deallocate(state.task, allocation.address, allocation.size))
    }
}
