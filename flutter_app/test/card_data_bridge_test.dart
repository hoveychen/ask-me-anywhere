// P3 — CardDataBridge two-way loop logic, exercised against a real
// InMemoryDataModel (no FFI): local edits surface outward, remote applies land
// in the model without echoing back out.
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';

import 'package:flutter_app/src/data/card_data_bridge.dart';

void main() {
  test('a local edit fires onLocalChange with path + value', () {
    final model = InMemoryDataModel();
    final fired = <String>[];
    final bridge = CardDataBridge(
      dataModel: model,
      paths: ['/note'],
      onLocalChange: (path, value) => fired.add('$path=$value'),
    );
    addTearDown(bridge.dispose);

    model.update(DataPath('/note'), 'hello'); // simulates a TextField edit
    expect(fired, ['/note=hello']);
  });

  test('applyRemote lands in the model but does not echo back out', () {
    final model = InMemoryDataModel();
    final fired = <String>[];
    final bridge = CardDataBridge(
      dataModel: model,
      paths: ['/note'],
      onLocalChange: (path, value) => fired.add('$path=$value'),
    );
    addTearDown(bridge.dispose);

    bridge.applyRemote('/note', 'from-peer');
    expect(model.getValue<String>(DataPath('/note')), 'from-peer');
    expect(fired, isEmpty); // echo guarded — would ping-pong otherwise

    // A genuine local edit after a remote apply still surfaces.
    model.update(DataPath('/note'), 'typed-here');
    expect(fired, ['/note=typed-here']);
  });

  test('re-writing the same value does not fire again', () {
    final model = InMemoryDataModel();
    final fired = <String>[];
    final bridge = CardDataBridge(
      dataModel: model,
      paths: ['/note'],
      onLocalChange: (path, value) => fired.add(path),
    );
    addTearDown(bridge.dispose);

    model.update(DataPath('/note'), 'x');
    model.update(DataPath('/note'), 'x'); // unchanged → no notification
    expect(fired, ['/note']);
  });

  test('only declared paths are watched', () {
    final model = InMemoryDataModel();
    final fired = <String>[];
    final bridge = CardDataBridge(
      dataModel: model,
      paths: ['/note'],
      onLocalChange: (path, value) => fired.add(path),
    );
    addTearDown(bridge.dispose);

    model.update(DataPath('/other'), 'ignored');
    expect(fired, isEmpty);
  });
}
