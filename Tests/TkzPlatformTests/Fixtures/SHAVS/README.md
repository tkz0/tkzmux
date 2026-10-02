# NIST CAVP SHAVS vectors for SHA-256

`SHA256ShortMsg.rsp` and `SHA256LongMsg.rsp` are copied unmodified (CRLF line endings kept) from NIST's byte-oriented SHA test vectors, `shabytetestvectors.zip` (CAVS 11.0), published by the Cryptographic Algorithm Validation Program:

<https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip>

`Tests/TkzPlatformTests/SHA256Tests.swift` reads them through `#filePath`. They are a US Government work and not subject to copyright in the US.

| File | Vectors | SHA-256 |
|---|---|---|
| `shabytetestvectors.zip` | – | `929ef80b7b3418aca026643f6f248815913b60e01741a44bba9e118067f4c9b8` |
| `SHA256ShortMsg.rsp` | 65 (0 to 64 bytes) | `75e1cb83994638481808e225b9eb0c1ebd0c232d952ac42b61abce6363be283c` |
| `SHA256LongMsg.rsp` | 64 (163 to 6,400 bytes) | `6fac36f37360bcf74ffcf4465c18e30d6d5a04cc90885b901fc3130c16060974` |
