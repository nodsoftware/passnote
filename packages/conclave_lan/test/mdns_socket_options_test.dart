// The multicast socket options mDNS needs are not the same on every platform,
// and getting either one wrong kills discovery silently on exactly one OS
// while the others stay green. Both directions were shipped at once:
//
//  - asking for SO_REUSEPORT where the runtime does not implement it made
//    every browse throw, so Android found nobody;
//  - not asking for it on an Apple host, which runs its own mDNSResponder and
//    already holds UDP 5353, made the responder fail to bind, so macOS
//    advertised to nobody.
//
// These pin the platform contract itself rather than Conclave's use of it, so
// a runtime or OS change that invalidates the rule fails here with an
// explanation instead of as a mysterious loss of discovery on one device.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// The rule [LanTransport] encodes: ask for `SO_REUSEPORT` on Apple platforms
/// and nowhere else.
bool get _conclaveAsksForReusePort => Platform.isMacOS || Platform.isIOS;

void main() {
  test('an ephemeral UDP bind accepts reusePort exactly where we ask for it',
      () async {
    RawDatagramSocket? socket;
    Object? error;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: _conclaveAsksForReusePort,
      );
    } catch (e) {
      error = e;
    }
    socket?.close();
    expect(
      error,
      isNull,
      reason: 'binding with reusePort: $_conclaveAsksForReusePort was refused '
          'on ${Platform.operatingSystem}. If this platform has changed which '
          'socket options it implements, LanTransport._reusePort must change '
          'with it.',
    );
  });

  test('mDNS port 5353 is bindable on the terms this platform requires',
      () async {
    // A host with its own mDNS responder (every Apple one) already holds 5353,
    // and only SO_REUSEPORT lets a second listener share it — reuseAddress is
    // not enough. Where nothing contends for the port, a plain bind works.
    Future<Object?> bindError({required bool reusePort}) async {
      RawDatagramSocket? s;
      try {
        s = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          5353,
          reuseAddress: true,
          reusePort: reusePort,
        );
        return null;
      } catch (e) {
        return e;
      } finally {
        s?.close();
      }
    }

    expect(
      await bindError(reusePort: _conclaveAsksForReusePort),
      isNull,
      reason: 'the responder could not bind 5353 on '
          '${Platform.operatingSystem} with the options Conclave uses, so this '
          'node would advertise to nobody',
    );

    if (Platform.isMacOS || Platform.isIOS) {
      expect(
        await bindError(reusePort: false),
        isNotNull,
        reason: 'this platform is expected to already hold 5353, which is the '
            'whole reason the responder asks for SO_REUSEPORT. If it no longer '
            'does, the option is merely harmless here rather than required.',
      );
    }
  }, onPlatform: {
    // A container without a host network may have no usable interface for
    // 5353 at all; that is an environment limit, not a Conclave defect.
    'linux': const Skip('5353 availability is environment-dependent on CI'),
  });
}
