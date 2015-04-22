//
//  Logger.swift
//  Evergreen
//
//  Created by Nils Fischer on 19.08.14.
//  Copyright (c) 2014 viWiD Webdesign & iOS Development. All rights reserved.
//


import Foundation


// MARK: Global Interface


/// The default logger singleton
private let defaultLogger: Logger = {
    let logger = Logger(key: "Default", parent: nil)
    logger.handlers.append(ConsoleHandler())
    return logger
}()

/// The default logger's log level
public var logLevel: LogLevel? {
    get {
        return defaultLogger.logLevel
    }
    set {
        defaultLogger.logLevel = newValue
    }
}

/// Logs an event using a logger that is appropriate for the caller.
public func log<M>(message: M, forLevel logLevel: LogLevel? = nil, function: String = __FUNCTION__, file: String = __FILE__, line: Int = __LINE__)
{
    Logger.loggerForFile(file: file).log(message, forLevel: logLevel, function: function, file: file, line: line)
}



/// The queue used for logging
internal let loggingQueue = NSOperationQueue() // TODO: use to fix unordered println output


public final class Logger {
    
    
    // MARK: Public Properties

    /// This logger will only log events with equal or higher log levels. If no log level is specified, all events will be logged.
    public var logLevel: LogLevel?
    /// Returns the effective log level by reaching up the logger hierarchy until a logger specifies a log level.
    public var effectiveLogLevel: LogLevel? {
        if let logLevel = self.logLevel {
            return logLevel
        } else {
            if let parent = self.parent {
                return parent.effectiveLogLevel
            } else {
                return nil
            }
        }
    }
    
    /// The handlers provided by this logger to process log events.
    public var handlers = [Handler]()
    
    /// Passes log events up the logger hierarchy if set to true (default)
    public var shouldPropagate = true

    /// The parent in the logger hierarchy
    public let parent: Logger?
    private var children = [ String : Logger]()
    
    /// The key used to identify this logger
    public let key: String
    public var keyPath: KeyPath {
        if let parent = self.parent {
            return parent.keyPath.keyPathByAppendingComponent(self.key)
        } else {
            return KeyPath(components: [ self.key ])
        }
    }


    // MARK: Initialization
    
    /// Creates a new logger. If you don't specify a parent, the logger is detached from the logger hierarchy and will not have any handlers.
    public init(key: String, parent: Logger?) {
        self.key = key
        self.parent = parent
        parent?.children[key] = self
    }
    
    
    // MARK: Logging
    
    public func log<M>(message: M, forLevel logLevel: LogLevel? = nil, function: String = __FUNCTION__, file: String = __FILE__, line: Int = __LINE__)
    {
        let event = Event(keyPath: keyPath, message: message, logLevel: logLevel, date: NSDate(), elapsedTime: nil, function: function, file: file, line: line)
        self.logEvent(event)
    }
    
    public func logEvent<M>(event: Event<M>)
    {
        self.logInitialInfo()
        
        if let effectiveLogLevel = self.effectiveLogLevel {
            if let eventLogLevel = event.logLevel {
                if eventLogLevel < effectiveLogLevel {
                    return
                }
            }
        }
        
        self.handleEvent(event)
    }
    
    private func logInitialInfo() {
        if !hasLoggedInitialInfo {
            if handlers.count > 0 {
                let event = Event(keyPath: self.keyPath, message: "Logging to \(handlers)...", logLevel: .Info, date: NSDate(), elapsedTime: nil, function: __FUNCTION__, file: __FILE__, line: __LINE__)
                self.handleEvent(event)
            }
        }
        hasLoggedInitialInfo = true
        if shouldPropagate {
            if let parent = self.parent {
                parent.logInitialInfo()
            }
        }
    }
    
    private var hasLoggedInitialInfo = false

    // TODO: necessary?
    public var handlerHierarchyDescription: String {
        let handlerDescription = self.key + self.handlers.description
        if let parent = self.parent {
            return parent.handlerHierarchyDescription + " > " + handlerDescription
        } else {
            return handlerDescription
        }
    }
    
    private func handleEvent<M>(event: Event<M>)
    {
        for handler in handlers.filter({ handler in
            if let handlerLogLevel = handler.logLevel {
                if let eventLogLevel = event.logLevel {
                    if eventLogLevel < handlerLogLevel {
                        return false
                    }
                }
            }
            return true
        }) {
            handler.emitEvent(event)
        }
        if shouldPropagate {
            if let parent = self.parent {
                parent.handleEvent(event)
            }
        }
    }
    
    
    // MARK: Measuring Time
    
    private var defaultStartDate: NSDate?
    private lazy var startDates = [String : NSDate]()
    
    // TODO: log "Tic..." message by default
    public func tic<M>(andLog message: M, forLevel logLevel: LogLevel? = nil, timerKey: String? = nil, function: String = __FUNCTION__, file: String = __FILE__, line: Int = __LINE__)
    {
        if let timerKey = timerKey {
            startDates[timerKey] = NSDate()
        } else {
            defaultStartDate = NSDate()
        }
        self.log(message, forLevel: logLevel, function: function, file: file, line: line)
    }
    
    // TODO: log "...Toc" message by default
    public func toc<M>(andLog message: M, forLevel logLevel: LogLevel? = nil, timerKey: String? = nil, function: String = __FUNCTION__, file: String = __FILE__, line: Int = __LINE__)
    {
        var startDate: NSDate?
        if let timerKey = timerKey {
            startDate = startDates[timerKey]
        } else {
            startDate = defaultStartDate
        }
        if let startDate = startDate {
            let elapsedTime = NSDate().timeIntervalSinceDate(startDate)
            let event = Event(keyPath: keyPath, message: message, logLevel: logLevel, date: NSDate(), elapsedTime: elapsedTime, function: function, file: file, line: line)
            self.logEvent(event)
        }
    }

    
    // MARK: Logger Hierarchy
    
    /// The default logger is the root of the logger hierarchy.
    public class func defaultLogger() -> Logger {
        return Evergreen.defaultLogger
    }
    
    public class func loggerWithParent(parent: Logger, title: String = __FILE__) -> Logger {
        return parent.childForKeyPath(KeyPath(string: title))
    }
    
    public class func loggerForFile(file: String = __FILE__) -> Logger {
        // TODO: filename processing.. there has to be a better way
        let filename = file.lastPathComponent.componentsSeparatedByString(".").first!
        return self.loggerForKeyPath(KeyPath(components: [ filename ]))
    }
    
    /// Returns the logger for the specified key path. A key path is a dot-separated string of keys like "MyModule.MyClass" describing the logger hierarchy relative to the default logger. Always returns the same logger object for a given key path. A parent-children relationship is established and can be used to set specific settings like log levels and handlers for only parts of the logger hierarchy.
    public class func loggerForKeyPath(keyPath: Logger.KeyPath) -> Logger {
        let (key, remainingKeyPath) = keyPath.popFirst()
        if let key = key {
            if key == self.defaultLogger().key {
                return self.defaultLogger().childForKeyPath(remainingKeyPath)
            } else {
                return self.defaultLogger().childForKeyPath(keyPath)
            }
        } else {
            return self.defaultLogger()
        }
    }

    public func childForKeyPath(keyPath: KeyPath) -> Logger {
        let (key, remainingKeyPath) = keyPath.popFirst()
        if let key = key {
            let child = children[key] ?? Logger(key: key, parent: self)
            return child.childForKeyPath(remainingKeyPath)
        } else {
            return self
        }
    }
    
    // MARK: Key Path Struct
    
    public struct KeyPath: StringLiteralConvertible, Printable {
        public let components: [String]

        public init(components: [String]) {
            self.components = components
        }
        
        public init(string: String) {
            self.components = string.componentsSeparatedByString(".")
        }

        public func keyPathByAppendingComponent(component: String) -> KeyPath {
            return KeyPath(components: components + [ component ])
        }

        public typealias ExtendedGraphemeClusterLiteralType = StringLiteralType
        public init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
            self.components = value.componentsSeparatedByString(".")
        }
        public typealias UnicodeScalarLiteralType = StringLiteralType
        public init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
            self.components = value.componentsSeparatedByString(".")
        }
        public init(stringLiteral value: StringLiteralType) {
            self.components = value.componentsSeparatedByString(".")
        }
        
        public func popFirst() -> (key: String?, remainingKeyPath: KeyPath) {
            let key = components.first
            let remainingKeyPath: KeyPath = (components.count > 1) ? KeyPath(components: Array(components[1..<components.count])) : KeyPath(components: [String]())
            return (key, remainingKeyPath)
        }
        
        public var description: String {
            return descriptionWithSeparator(".")
        }
        
        public func descriptionWithSeparator(separator: String) -> String {
            return separator.join(components)
        }
    }

}


// MARK: - Printable

extension Logger: Printable {

    public var description: String {
        if let parent = self.parent {
            if parent === Logger.defaultLogger() {
                return key
            } else {
                return parent.description + "." + key
            }
        } else {
            if self === Logger.defaultLogger() {
                return key
            } else {
                return "DETACHED." + key
            }
        }
    }

}


// MARK: - Log Level Enum

public enum LogLevel: Int, Printable, Comparable {

    case All = 0, Verbose, Debug, Info, Warning, Critical, Off

    public var description: String {
        switch self {
            case .All: return "All"
            case .Verbose: return "Verbose"
            case .Debug: return "Debug"
            case .Info: return "Info"
            case .Warning: return "Warning"
            case .Critical: return "Critical"
            case .Off: return "Off"
        }
    }
}

public func == (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue == rhs.rawValue
}

public func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
}


// MARK: - Log Event Struct

public struct Event<M> {
    
    /// The Key Path the Event was originally logged for
    let keyPath: Logger.KeyPath
    /// The log message
    let message: M
    /// The log level. A logger will only log events with equal or higher log levels than its own. Events that don't specify a log level will always be logged.
    let logLevel: LogLevel?
    let date: NSDate
    let elapsedTime: NSTimeInterval?
    
    let function: String
    let file: String
    let line: Int
    
}


// MARK: - Loggable Protocol

// TODO: define Loggable protocol as a constraint for generic message type M.
//public typealias Loggable = DebugPrintable
