//
//  ImageAttachPlan.swift
//  The disk image layer of an attach, given what is already bound to the path.
//
//  Attach is idempotent: a LUN whose image already has a device is reported as
//  attached rather than attached twice. That is right only while the device is
//  backed by the FSKit volume serving the image now. Logging out with a volume
//  attached takes the FSKit mount down but can leave the device behind — its
//  eject fails — still bound to the same image path and serving nothing
//  (measured 2026-10-22: the next login "attached" a dead disk, no volume, no
//  error). A device that exists when the FSKit mount under it had to be created
//  just now predates that mount, so it is stale by construction.
//

import Foundation

public enum ImageAttachPlan: Sendable, Equatable {
    /// Nothing is bound to the image: `hdiutil attach` it.
    case attach
    /// Already attached over the FSKit volume that is serving it now.
    case reuse(device: String)
    /// Attached over an earlier FSKit volume that is gone: detach, then attach.
    case replaceStale(device: String)

    /// - Parameters:
    ///   - fskitWasMounted: the FSKit volume serving the image was already up
    ///     before this attach (false when this attach had to `mount -F` it).
    ///   - existingDevice: what `hdiutil info` has bound to the image path.
    public static func decide(fskitWasMounted: Bool, existingDevice: String?) -> ImageAttachPlan {
        guard let existingDevice else { return .attach }
        return fskitWasMounted ? .reuse(device: existingDevice)
                               : .replaceStale(device: existingDevice)
    }
}
