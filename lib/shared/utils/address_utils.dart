/// Re-export of the canonical address truncation helper.
///
/// The implementation lives in `lib/core/utils/address_format.dart` and
/// defaults to 5/5 truncation with a single `…` separator (matches the
/// Figma artwork-detail spec). Callers needing the legacy 4/4 form should
/// pass `lead: 4, trail: 4` explicitly.
library;

export '../../core/utils/address_format.dart' show truncateAddress;
