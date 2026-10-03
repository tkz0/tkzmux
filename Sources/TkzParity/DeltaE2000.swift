// DeltaE2000 — CIEDE2000 colour difference, reported and never gated (ADR-0003 §1; WOR-322 S1).
//
// The contract is equal gamma-encoded bytes. ΔE2000 only tells a reader how visible a difference
// is: a run whose channel rule fails at ΔE 0.3 is a rounding disagreement, at ΔE 8 a wrong token.
// Bytes are read as sRGB (IEC 61966-2-1) with a D65 white, through CIE XYZ to CIELAB, and the
// difference follows Sharma, Wu and Dalal 2005 with kL = kC = kH = 1.

import Foundation

public enum DeltaE2000 {
    public struct Lab: Equatable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double

        public init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }
    }

    /// One 8-bit sRGB colour in CIELAB (D65).
    public static func lab(r: UInt8, g: UInt8, b: UInt8) -> Lab {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIEDE2000 between two CIELAB colours.
    public static func difference(_ lab1: Lab, _ lab2: Lab) -> Double {
        let radiansPerDegree = Double.pi / 180
        let c1 = (lab1.a * lab1.a + lab1.b * lab1.b).squareRoot()
        let c2 = (lab2.a * lab2.a + lab2.b * lab2.b).squareRoot()
        let cMean = (c1 + c2) / 2
        let cMean7 = pow(cMean, 7)
        let g = 0.5 * (1 - (cMean7 / (cMean7 + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * lab1.a, a2 = (1 + g) * lab2.a
        let c1p = (a1 * a1 + lab1.b * lab1.b).squareRoot()
        let c2p = (a2 * a2 + lab2.b * lab2.b).squareRoot()

        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let degrees = atan2(b, a) / radiansPerDegree
            return degrees >= 0 ? degrees : degrees + 360
        }
        let h1 = hue(lab1.b, a1), h2 = hue(lab2.b, a2)

        let dL = lab2.l - lab1.l
        let dC = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (c1p * c2p).squareRoot() * sin(dh / 2 * radiansPerDegree)

        let lMean = (lab1.l + lab2.l) / 2
        let cpMean = (c1p + c2p) / 2
        var hMean = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) <= 180 {
                hMean = (h1 + h2) / 2
            } else if h1 + h2 < 360 {
                hMean = (h1 + h2 + 360) / 2
            } else {
                hMean = (h1 + h2 - 360) / 2
            }
        }
        let t = 1
            - 0.17 * cos((hMean - 30) * radiansPerDegree)
            + 0.24 * cos(2 * hMean * radiansPerDegree)
            + 0.32 * cos((3 * hMean + 6) * radiansPerDegree)
            - 0.20 * cos((4 * hMean - 63) * radiansPerDegree)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let cpMean7 = pow(cpMean, 7)
        let rc = 2 * (cpMean7 / (cpMean7 + pow(25, 7))).squareRoot()
        let lOffset = (lMean - 50) * (lMean - 50)
        let sl = 1 + 0.015 * lOffset / (20 + lOffset).squareRoot()
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * radiansPerDegree) * rc

        let tl = dL / sl, tc = dC / sc, th = dH / sh
        return (tl * tl + tc * tc + th * th + rt * tc * th).squareRoot()
    }

    /// The mean and 99th percentile (nearest rank) of ΔE2000 over the unmasked pixels of two
    /// equal-size images, reading premultiplied RGB (so a translucent pixel counts as composited
    /// over black). Nil when every pixel is masked.
    public static func summary(_ a: ParityImage, _ b: ParityImage, mask: MaskBitmap) -> DeltaESummary? {
        precondition(a.width == b.width && a.height == b.height)
        var values: [Double] = []
        values.reserveCapacity(a.pixelCount)
        // Frames have few distinct colour pairs; each pair is converted once.
        var cache: [UInt64: Double] = [:]
        for index in 0..<a.pixelCount where !mask.isMasked(index) {
            let base = index * 4
            let ca = UInt64(a.bgra[base]) | UInt64(a.bgra[base + 1]) << 8 | UInt64(a.bgra[base + 2]) << 16
            let cb = UInt64(b.bgra[base]) | UInt64(b.bgra[base + 1]) << 8 | UInt64(b.bgra[base + 2]) << 16
            if ca == cb {
                values.append(0)
                continue
            }
            let key = ca << 24 | cb
            if let cached = cache[key] {
                values.append(cached)
                continue
            }
            let value = difference(
                lab(r: a.bgra[base + 2], g: a.bgra[base + 1], b: a.bgra[base]),
                lab(r: b.bgra[base + 2], g: b.bgra[base + 1], b: b.bgra[base]))
            cache[key] = value
            values.append(value)
        }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        values.sort()
        let rank = (99 * values.count + 99) / 100  // ⌈0.99 n⌉ in integers
        return DeltaESummary(mean: mean, p99: values[rank - 1], comparedPixels: values.count)
    }
}

public struct DeltaESummary: Codable, Equatable, Sendable {
    public let mean: Double
    public let p99: Double
    public let comparedPixels: Int
    /// Always true: ΔE2000 never gates (ADR-0003 §1).
    public var diagnosticOnly = true

    public init(mean: Double, p99: Double, comparedPixels: Int) {
        self.mean = mean
        self.p99 = p99
        self.comparedPixels = comparedPixels
    }
}
