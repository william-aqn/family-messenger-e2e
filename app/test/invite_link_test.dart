import 'package:family_messenger_e2e/api/invite_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a link and tolerates a trailing slash on the origin', () {
    expect(inviteLink('k7m2q9zr4x1b3n5p', 'https://chat.example.com'),
        'https://chat.example.com/#/join?code=k7m2q9zr4x1b3n5p');
    expect(inviteLink('k7m2q9zr4x1b3n5p', 'https://chat.example.com/'),
        'https://chat.example.com/#/join?code=k7m2q9zr4x1b3n5p');
    expect(inviteLink('a b/c', 'https://chat.example.com'),
        'https://chat.example.com/#/join?code=a%20b%2Fc');
  });

  test('reads a full link', () {
    final full = parseInviteLink('https://chat.example.com/#/join?code=k7m2q9zr4x1b3n5p');
    expect(full, const InviteLink('https://chat.example.com', 'k7m2q9zr4x1b3n5p'));

    // A trailing slash on the origin and an extra fragment parameter.
    expect(parseInviteLink('https://chat.example.com/#/join?code=abcd1234&x=1'),
        const InviteLink('https://chat.example.com', 'abcd1234'));

    // What inviteLink() produces round-trips.
    final built = inviteLink('k7m2q9zr4x1b3n5p', 'https://chat.example.com/');
    expect(parseInviteLink(built)?.code, 'k7m2q9zr4x1b3n5p');
  });

  test('reads a link that carries a query before the hash', () {
    expect(parseInviteLink('https://chat.example.com/?utm=qr#/join?code=k7m2q9zr4x1b3n5p'),
        const InviteLink('https://chat.example.com', 'k7m2q9zr4x1b3n5p'));
    // The code itself may sit in that query instead of the fragment.
    expect(parseInviteLink('https://chat.example.com/join?code=k7m2q9zr4x1b3n5p'),
        const InviteLink('https://chat.example.com', 'k7m2q9zr4x1b3n5p'));
  });

  test('reads a bare code', () {
    expect(parseInviteLink('k7m2q9zr4x1b3n5p'), const InviteLink('', 'k7m2q9zr4x1b3n5p'));
    expect(parseInviteLink('  FM-7K2Q-9ZR4  '), const InviteLink('', 'FM-7K2Q-9ZR4'));
  });

  test('rejects rubbish and a link without a code', () {
    expect(parseInviteLink(''), isNull);
    expect(parseInviteLink('   '), isNull);
    expect(parseInviteLink('hello there'), isNull);
    expect(parseInviteLink('https://chat.example.com/'), isNull);
    expect(parseInviteLink('https://chat.example.com/#/join'), isNull);
    expect(parseInviteLink('https://chat.example.com/#/join?code='), isNull);
    expect(parseInviteLink('WIFI:S:home;T:WPA;P:secret;;'), isNull);
  });
}
