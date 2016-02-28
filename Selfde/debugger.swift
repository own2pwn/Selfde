//
//  debugger.swift
//  Selfde
//

// Read/Write/Execute memory permissions.
struct MemoryPermissions: OptionSetType {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = 0 }
    
    static let Read = MemoryPermissions(rawValue: 1)
    static let Write = MemoryPermissions(rawValue: 2)
    static let Execute = MemoryPermissions(rawValue: 4)
}

enum MemoryReadResult {
    case Bytes(UnsafeBufferPointer<UInt8>)
}

enum ThreadReference {
    case ID(UInt) // NNN
    case Any      // 0
    case All      // -1
}

enum ThreadResumeAction: Int {
    case None
    case Stop
    case Continue
    case Step
}

struct ThreadResumeEntry {
    let thread: ThreadReference
    let action: ThreadResumeAction
    let address: COpaquePointer?
}

protocol Debugger: class {
    var registerContextSize: Int { get }

    var primaryThreadID: UInt { get }

    func attach(processID: Int) throws
    func killInferior() throws
    func getSharedLibraryInfoAddress() throws -> COpaquePointer

    func resume(actions: [ThreadResumeEntry], defaultAction: ThreadResumeAction) throws

    // TODO: ref count up
    func setBreakpoint(address: COpaquePointer, byteSize: Int) throws
    func removeBreakpoint(address: COpaquePointer) throws

    func getRegisterValueForThread(threadID: UInt, registerID: UInt32, registerSetID: UInt32, inout dest: [UInt8]) throws -> ArraySlice<UInt8>
    func setRegisterValueForThread(threadID: UInt, registerID: UInt32, registerSetID: UInt32, source: ArraySlice<UInt8>) throws

    func getRegisterContextForThread(threadID: UInt, inout dest: [UInt8]) throws -> ArraySlice<UInt8>
    func setRegisterContextForThread(threadID: UInt, source: ArraySlice<UInt8>) throws

    func allocate(size: Int, permissions: MemoryPermissions) throws -> COpaquePointer
    func deallocate(address: COpaquePointer) throws
    
    func readMemory(address: COpaquePointer, size: Int) throws -> MemoryReadResult
    func writeMemory(address: COpaquePointer, bytes: [UInt8]) throws
}