// FreeTypeLibrary — the one `FT_Library` a font stack owns, with stem darkening pinned off (WOR-312 S3).
//
// `FT_Init_FreeType` applies `FREETYPE_PROPERTIES` from the environment as it creates the library
// (Arch ships /etc/profile.d/freetype2.sh for exactly that, and users set
// `cff:no-stem-darkening=0`). Stem darkening thickens CFF, Type 1 and autohinted glyphs by an amount
// that depends on the size, so any setting other than "off" breaks mask parity with the Mac. The
// properties are therefore set again immediately after init, which overrides whatever the
// environment said: the output never depends on the user's FreeType configuration (ADR-0002).
//
// Not Sendable. FreeType objects may be used from one thread at a time; a library and the faces
// opened from it live together in one owner behind a `Mutex` (`TerminalFaces`).

import CFreeType

/// A failed FreeType call: the function's name and its `FT_Error`.
public struct FreeTypeError: Error, Sendable, Equatable, CustomStringConvertible {
    public let call: String
    public let code: Int32

    public init(call: String, code: Int32) {
        self.call = call
        self.code = code
    }

    public var description: String {
        let message = FT_Error_String(FT_Error(code)).map { String(cString: $0) } ?? "error"
        return "\(call) failed: \(message) (0x\(String(code, radix: 16)))"
    }
}

final class FreeTypeLibrary {
    /// The FreeType modules that implement stem darkening. `no-stem-darkening` is TRUE on all four.
    static let darkeningModules = ["cff", "type1", "t1cid", "autofitter"]
    static let noStemDarkening = "no-stem-darkening"

    let handle: FT_Library

    init() throws(FreeTypeError) {
        var library: FT_Library?
        let error = FT_Init_FreeType(&library)
        guard error == 0, let library else { throw FreeTypeError(call: "FT_Init_FreeType", code: error) }
        // Before anything else touches the library, so no face is ever opened with darkening on.
        do {
            try Self.disableStemDarkening(library)
        } catch {
            FT_Done_FreeType(library)
            throw error
        }
        self.handle = library
    }

    deinit {
        FT_Done_FreeType(handle)
    }

    /// Sets `no-stem-darkening` to TRUE on every darkening module. A module compiled out of this
    /// FreeType build cannot darken, so `Missing_Module` is not an error; anything else is.
    static func disableStemDarkening(_ library: FT_Library) throws(FreeTypeError) {
        for module in darkeningModules {
            var noDarkening: FT_Bool = 1
            let error = FT_Property_Set(library, module, noStemDarkening, &noDarkening)
            guard error == 0 || error == FT_Error(FT_Err_Missing_Module) else {
                throw FreeTypeError(call: "FT_Property_Set(\(module), \(noStemDarkening))", code: error)
            }
        }
    }

    /// `no-stem-darkening` as `module` reports it, or `nil` when the module is absent.
    func isStemDarkeningDisabled(module: String) -> Bool? {
        Self.isStemDarkeningDisabled(handle, module: module)
    }

    static func isStemDarkeningDisabled(_ library: FT_Library, module: String) -> Bool? {
        var noDarkening: FT_Bool = 0
        guard FT_Property_Get(library, module, noStemDarkening, &noDarkening) == 0 else { return nil }
        return noDarkening != 0
    }
}
