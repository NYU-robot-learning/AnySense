//
//  dataStorage.swift
//  AnySense
//
//  Created by Michael on 2025/2/1.
//
import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct TextFile: FileDocument {
    // tell the system we support only plain text
    static var readableContentTypes = [UTType.text]

    var text = ""
    var url : String

    init(url : String){
        self.url = url
    }
    
    // this initializer loads data/Users/bianzeyu/Documents/PolySense/AnySense/dataStorage.swift that has been saved previously
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        }
        url = ""
    }


    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let file = try! FileWrapper(url: URL(fileURLWithPath: url), options: .immediate)
        return file
    }
}

struct VideoFile: FileDocument{
    var url: URL
    
    static var readableContentTypes: [UTType] { [.mpeg4Movie] }
    static var writableContentTypes: [UTType] { [.mpeg4Movie] }
        
    // Initialize with a given URL
    init(url: URL) {
        self.url = url
    }
        
    // This is called when the system wants to read the previously saved data
    init(configuration: ReadConfiguration) throws {
        self.url = URL(fileURLWithPath: "")
    }
        
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            return try FileWrapper(url: url, options: .immediate)
    }
}

struct ImageFile: FileDocument {
    var url: URL
    
    static var readableContentTypes: [UTType] { [.jpeg] }
    static var writableContentTypes: [UTType] { [.jpeg] }
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        self.url = URL(fileURLWithPath: "")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            return try FileWrapper(url: url, options: .immediate)
    }
    
        
}
enum FileElement {
    case videoFile(VideoFile)
    case textFile(TextFile)
    case directory(SubLevelDirectory)
}

enum FileElementSub {
    case imageFile(ImageFile)
}

struct SubLevelDirectory: FileDocument{
    var url: URL
    var containedFiles: [FileElementSub]
    
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }
    
    init(url: URL) {
        self.url = url
        self.containedFiles = []
        do{
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for content in contents{
                if content.pathExtension.lowercased() == "ipeg" || content.pathExtension.lowercased() == "jpg" {
                    self.containedFiles.append(.imageFile(ImageFile(url: content)))
                }
            }
        }catch{
            print("Error when extract and append files to export directory")
        }
    }
    
    init(configuration: ReadConfiguration) throws {
        self.url = URL(fileURLWithPath: "")
        self.containedFiles = []
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let dirWrapper = FileWrapper(directoryWithFileWrappers: [:])
        for file in containedFiles {
            switch file {
        
            case .imageFile(let imageFile):
                let fileWrapper = try imageFile.fileWrapper(configuration: configuration)
                dirWrapper.addFileWrapper(fileWrapper)
            }
        }
        return dirWrapper
    }
}
    
    
    struct DocumentaryFolder: FileDocument {
        var files: [FileElement]
        
        
        static var readableContentTypes: [UTType] { [.folder] }
        static var writableContentTypes: [UTType] { [.folder] }
        
        
        init(files: [FileElement]) {
            self.files = files
        }
        
        
        init(configuration: ReadConfiguration) throws {
            self.files = []
            // Implement reading logic if needed
        }
        
        
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            let folderWrapper = FileWrapper(directoryWithFileWrappers: [:])
            
            
            for file in files {
                switch file {
                case .videoFile(let videoFile):
                    let fileWrapper = try videoFile.fileWrapper(configuration: configuration)
                    fileWrapper.preferredFilename = videoFile.url.lastPathComponent
                    folderWrapper.addFileWrapper(fileWrapper)
                case .textFile(let textFile):
                    let fileWrapper = try textFile.fileWrapper(configuration: configuration)
                    fileWrapper.preferredFilename = URL(fileURLWithPath: textFile.url).lastPathComponent
                    folderWrapper.addFileWrapper(fileWrapper)
                case .directory(let directory):
                    let directoryWrapper = try directory.fileWrapper(configuration: configuration)
                    directoryWrapper.preferredFilename = directory.url.lastPathComponent
                    folderWrapper.addFileWrapper(directoryWrapper)
                }
            }
            
            return folderWrapper
        }
    }
