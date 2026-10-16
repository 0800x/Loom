import 'package:loom_next/features/messaging/application/live_location_projection.dart';
import 'package:flutter_test/flutter_test.dart';

class Point {
  const Point(this.id, this.order, this.sender, this.point);
  final String id, sender;
  final int order;
  final Map<String, Object?>? point;
}

Map<String, Object?> fix(int at, {bool stopped = false, int until = 1000}) => {
  'session': 'one',
  'at': at,
  'until': until,
  'stopped': stopped,
  'lat': at / 10,
  'lon': 51.0,
};
List<Point> project(List<Point> data) => projectLoomLiveLocations(
  data,
  location: (p) => p.point,
  sender: (p) => p.sender,
  compare: (a, b) => a.order.compareTo(b.order),
  merge: (anchor, latest) =>
      Point(anchor.id, anchor.order, anchor.sender, latest.point),
);
void main() {
  test(
    'updates preserve the original anchor among ordinary messages and other senders',
    () {
      final result = project([
        Point('later', 3, 'alice', fix(30)),
        Point('first', 1, 'alice', fix(10)),
        const Point('text', 2, 'alice', null),
        Point('bob', 4, 'bob', fix(40)),
      ]);
      expect(result.map((p) => p.id), ['first', 'text', 'bob']);
      expect(result.first.point!['at'], 30);
    },
  );
  test(
    'a delayed GPS update cannot revive a stopped share or extend its expiry',
    () {
      final result = project([
        Point('first', 1, 'alice', fix(10)),
        Point('stop', 2, 'alice', fix(20, stopped: true)),
        Point('delayed', 3, 'alice', fix(30)),
        Point('extended', 4, 'alice', fix(40, until: 2000)),
      ]);
      expect(result.single.id, 'first');
      expect(result.single.point!['stopped'], true);
      expect(result.single.point!['at'], 20);
      expect(result.single.point!['until'], 1000);
    },
  );
}
