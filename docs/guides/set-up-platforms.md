# Set up platforms

Two one-time steps per app: select the SQLCipher build of SQLite (all
platforms), and declare the local-network permissions (per platform).

## At-rest encryption: select SQLCipher

`package:sqlite3` bundles its native library through build hooks, and the
default build is plain SQLite. Select the SQLCipher source in your **app's
root `pubspec.yaml`** (the setting is read from the root package only):

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlcipher
```

This is not optional when you use encryption: the engine verifies `PRAGMA
cipher_version` after keying and throws `SqlCipherUnavailableException`
rather than write plaintext to disk. Seeing that exception means this stanza
is missing.

## Local-network permissions

`LanTransport` discovers peers with mDNS over multicast sockets. Every
desktop and mobile OS gates local-network traffic in its own way, and a
missing declaration never crashes the app: it runs, but no peers ever
appear. Detect that state in code by listening for the
`PeerDiscoveryUnavailable` event on `Passnote.events` and pointing the user
at the relevant section below. Do this page once per platform you ship to.

The example apps ship as `lib/` and `pubspec.yaml` only; run
`flutter create .` inside one to generate the platform folders, then apply
the sections below.

## iOS

Two things, both required:

**1. Declare local-network use in `ios/Runner/Info.plist`:**

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds your other devices on this network to sync your data directly, without a server.</string>
<key>NSBonjourServices</key>
<array>
  <!-- _passnote-<appId>._tcp, for your appId: -->
  <string>_passnote-shopping._tcp</string>
</array>
```

iOS shows the user a local-network permission prompt on first use. If the
user declines, discovery finds nothing until they enable it in Settings >
Privacy & Security > Local Network.

**2. Request the multicast entitlement.** Passnote's mDNS is pure Dart
(its own sockets, not Apple's Bonjour API), and iOS restricts direct
multicast to apps holding `com.apple.developer.networking.multicast`.
[Request it from Apple](https://developer.apple.com/contact/request/networking-multicast)
(peer-to-peer sync without a server is exactly its intended use case), then
add it to your entitlements. The iOS Simulator does not enforce any of this,
so "works in the simulator, silent on the device" usually means this section.

If the entitlement is not an option for your app, sync over
[`WebSocketTransport`](../reference/transports.md) with explicit addresses
instead; it needs none of the above.

## Android

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
```

Many devices filter incoming multicast unless the app holds a
`WifiManager.MulticastLock`. Acquire one while syncing (a few lines over a
platform channel, or any plugin that wraps the multicast lock); without it,
discovery works on some devices and not on others.

Android emulators sit behind per-instance NAT: two emulators cannot see each
other's multicast. Test discovery on real devices, or wire the emulators
together with `WebSocketTransport` and explicit addresses.

## macOS

Flutter macOS apps run in the App Sandbox. Add both network entitlements to
**both** `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements` (the release file has neither by
default):

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

macOS 15 and later also shows the local-network prompt; add
`NSLocalNetworkUsageDescription` to `macos/Runner/Info.plist` with the same
text as on iOS.

## Windows and Linux

No manifest changes. The OS firewall asks once when the app first listens;
the user must allow it on private networks. On managed machines a group
policy that blocks mDNS (UDP 5353) blocks discovery.

## Web

Browsers have no mDNS and cannot listen. Use `WebSocketTransport` with an
explicit address; the whole story is in
[Run on the web](run-on-the-web.md).

## The network itself

Permissions are half of it; the network must also carry multicast:

- Guest Wi-Fi and hotel/office networks often enable *client isolation*,
  which blocks device-to-device traffic entirely.
- Corporate VLANs commonly drop multicast across segments.
- A phone hotspot works and is a quick way to rule the network out.

When devices still cannot see each other, walk through
[Troubleshoot sync](troubleshoot-sync.md).
