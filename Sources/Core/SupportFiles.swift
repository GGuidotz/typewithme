// Permessi dei file che l'app scrive in Application Support: la cartella solo per chi usa il Mac (0700), i file 0600.
// Solo Foundation.

import Foundation

enum SupportFiles {
    /// Crea la cartella (o la ritocca se c'è già) con permessi 0700 e porta a 0600 i file che già contiene.
    static func prepare(_ folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue { protect(file) }
        }
    }

    /// Un file scritto da noi: leggibile solo da chi usa il Mac (0600).
    static func protect(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
