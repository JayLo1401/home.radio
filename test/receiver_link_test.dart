import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_system/features/home/connection_chain.dart';

void main() {
  for (final width in [500.0, 1100.0]) {
    testWidgets('the chain lays out without overflow at $width px', (tester) async {
      final link = ReceiverLink()..start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 1);
      link.setServerReady(true);
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SizedBox(width: width, child: ConnectionChain(view: link.view))),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      link.fail(LinkStage.stick, 'Ein sehr langer Fehlertext, der nicht in die Zeile passt und gekürzt wird', retrying: false);
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SizedBox(width: width, child: ConnectionChain(view: link.view))),
      ));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Ein sehr langer'), findsOneWidget);
    });
  }

  test('DAB+ over rtl_tcp: server, stick, station turn green as the receiver reports them', () {
    final link = ReceiverLink()..start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 0x1234);
    var v = link.view;
    expect([v.server, v.stick, v.station], [LinkState.active, LinkState.pending, LinkState.pending]);

    link.setServerReady(true); // setServer's TCP probe
    v = link.view;
    expect([v.server, v.stick, v.station], [LinkState.done, LinkState.active, LinkState.pending]);

    link.onEvent({'type': 'connectionMessage', 'isError': false, 'message': 'Verbindung zur rtl_tcp-Quelle hergestellt'});
    v = link.view;
    expect([v.server, v.stick, v.station], [LinkState.done, LinkState.done, LinkState.active]);
    expect(v.message, 'Kanal 11D wird gesucht…');

    link.onEvent({'type': 'ensembleLabel', 'label': 'ORF Wien'});
    expect(link.view.message, 'Ensemble „ORF Wien“ gefunden');
    expect(link.complete, isFalse);

    link.tuned(true); // playService verified audio
    expect(link.view.station, LinkState.done);
    expect(link.complete, isTrue);
  });

  test('a busy stick fails the stick hop for good, an unreachable server keeps retrying', () {
    final link = ReceiverLink()..start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 1);
    link.setServerReady(true);
    link.onEvent({'type': 'connectionMessage', 'isError': true, 'message': '„Graz“ wird bereits von 192.168.1.20 verwendet'});
    expect(link.view.stick, LinkState.failed);
    expect(link.view.station, LinkState.pending);

    link.onEvent({'type': 'connectionMessage', 'isError': true, 'message': 'rtl_tcp-Quelle 10.0.0.2:1234 nicht erreichbar'});
    expect(link.view.server, LinkState.retrying);
    expect(link.view.message, contains('nicht erreichbar'));
  });

  test('FM is only complete with the first signal measurement; USB has no server node', () {
    final link = ReceiverLink()..start(viaServer: false, fm: true, freqKhz: 98500);
    expect(link.view.stick, LinkState.active);
    link.setServerReady(true); // useDirectUsb opened the stick
    expect(link.view.stick, LinkState.done);
    expect(link.view.message, '98,5 MHz wird eingestellt…');
    link.tuned(true);
    expect(link.complete, isFalse);
    link.onEvent({'type': 'fmStatus', 'freqKhz': 98500, 'snrDb': 20.0});
    expect(link.complete, isTrue);
  });

  test('a retry of the same station keeps showing why it is retrying', () {
    final link = ReceiverLink()..start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 1);
    link.tuned(false);
    link.fail(LinkStage.station, 'Kein Signal - versuche erneut…', retrying: true);
    link.start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 1);
    expect(link.view.station, LinkState.retrying);
    link.start(viaServer: true, fm: false, freqKhz: 222064, serviceId: 2);
    expect(link.hasError, isFalse);
  });
}
