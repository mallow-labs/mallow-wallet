import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/models/recipient_suggestion.dart';
import 'package:mallow_wallet/shared/utils/address_utils.dart';

void main() {
  const owner = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const squatter = 'Squatter11111111111111111111111111111111111';

  const real = RecipientSuggestion(address: owner, username: 'alice');

  group('a display name set to someone else\'s username', () {
    for (final name in [
      'alice',
      '@alice',
      '@@alice',
      '\uFF20alice',
      '\uFE6Balice',
      '\u200B@alice',
      '\u202E@alice',
      '@\u200Dalice',
    ]) {
      final row = RecipientSuggestion(address: squatter, displayName: name);

      test('${name.runes.toList()} cannot pass for the owner', () {
        expect(row.label, 'alice');
        expect(row.label, isNot(real.label));
        expect(row.isDisplayNameOnly, isTrue);
        expect(row.fieldText, squatter);
        expect(row.fieldText, isNot(real.fieldText));
      });
    }
  });

  test('only a username is written as a handle', () {
    expect(real.label, '@alice');
    expect(real.fieldText, '@alice');
    expect(real.isDisplayNameOnly, isFalse);
  });

  test('a username outranks a display name on the same profile', () {
    const row = RecipientSuggestion(
      address: owner,
      username: 'alice',
      displayName: 'Alice A',
    );
    expect(row.label, '@alice');
    expect(row.isDisplayNameOnly, isFalse);
  });

  test('an empty username is no username', () {
    const row = RecipientSuggestion(
      address: squatter,
      username: '',
      displayName: 'alice',
    );
    expect(row.label, 'alice');
    expect(row.fieldText, squatter);
    expect(row.isDisplayNameOnly, isTrue);
  });

  test('an ordinary display name keeps its words', () {
    const row = RecipientSuggestion(
      address: squatter,
      displayName: '  Alice   A ',
    );
    expect(row.label, 'Alice A');
  });

  test('a display name of nothing but mimicry falls back to the address', () {
    const row = RecipientSuggestion(address: squatter, displayName: '@\u200B@');
    expect(row.label, truncateAddress(squatter));
    expect(row.isDisplayNameOnly, isFalse);
    expect(row.fieldText, squatter);
  });

  test('a profile with neither name uses the address', () {
    const row = RecipientSuggestion(address: squatter);
    expect(row.isDisplayNameOnly, isFalse);
    expect(row.fieldText, squatter);
  });
}
