import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../config/environment.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import 'passkey_prf.dart';
import 'platform_backup_guard.dart';
import 'platform_slot_store.dart';
import 'social_vault_api.dart';
import 'social_vault_crypto.dart';

/// Opens, creates and edits social vaults: the slot logic between the backend
/// (ciphertext only), the platform slot store, passkeys and this device's
/// MnemonicVault.
///
/// Every secret this class touches — the data key, slot secrets, PRF
/// outputs, the payload — stays in memory or in MnemonicVault. What goes to
/// the backend is ciphertext, wrapped keys, salts, credential ids and the
/// vault public key; what goes to the platform slot store is one slot secret.
@lazySingleton
class SocialVaultService {
  SocialVaultService(
    this._api,
    this._platform,
    this._passkeys,
    this._storage, {
    PlatformBackupGuard? backup,
    @visibleForTesting Future<String> Function()? deviceName,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting Future<int?> Function()? androidSdkInt,
    @visibleForTesting String? Function()? apiOrigin,
  }) : _backup =
           backup ?? PlatformBackupGuard(_platform, _storage, clock: clock),
       _deviceName = deviceName ?? _defaultDeviceName,
       _clock = clock ?? DateTime.now,
       _androidSdkInt = androidSdkInt ?? _defaultAndroidSdkInt,
       _apiOriginOverride = apiOrigin;

  @factoryMethod
  static SocialVaultService forInjection(
    SocialVaultApi api,
    PlatformSlotStore platform,
    PasskeyPrfAuthenticator passkeys,
    SecureWalletStorage storage,
    PlatformBackupGuard backup,
  ) => SocialVaultService(api, platform, passkeys, storage, backup: backup);

  static const _tag = 'SocialVault';

  final SocialVaultApi _api;
  final PlatformSlotStore _platform;
  final PasskeyPrfAuthenticator _passkeys;
  final SecureWalletStorage _storage;
  final PlatformBackupGuard _backup;
  final Future<String> Function() _deviceName;
  final DateTime Function() _clock;
  final Future<int?> Function() _androidSdkInt;
  final String? Function()? _apiOriginOverride;

  SocialVaultApi get vaultApi => _api;

  // ---------------------------------------------------------------------------
  // One thing at a time
  // ---------------------------------------------------------------------------

  /// Everything that asks the backend about one vault and then acts on the
  /// answer here — a status read, every write, keeping or dropping this
  /// device's copy — runs through this, one at a time per vault.
  ///
  /// Unqueued, a status read and a write cross: the read is signed with the
  /// data key as it was, the write replaces that key, and the read's answer
  /// ("that signature does not verify", or the record from before the write)
  /// is then acted on against the new key and the new record. So each of
  /// them reads this device's key and record only once it holds the queue,
  /// and gives it up only after it has stored what the answer changed.
  ///
  /// A prompt the user paces (a passkey sheet) is never inside it.
  final _Serial _operations = _Serial();

  /// Read-modify-write of the small records this class keeps in the plugin
  /// store (the cached vault record, the journals), one at a time per
  /// record. Never held across a request, so the screens that acknowledge a
  /// notice do not wait for the network.
  final _Serial _records = _Serial();

  // ---------------------------------------------------------------------------
  // The backend a vault lives on
  // ---------------------------------------------------------------------------
  //
  // "No such vault" is true of every vault on every backend but the one that
  // holds it. A build pointed at another backend (a staging build over a
  // production install, a changed variable) would get that answer for each
  // vault, with the backend's own code on it. So each record of a vault
  // names the backend that showed the vault exists — its origin: scheme,
  // host and port, since two backends can share a host — and "not found" is
  // believed only from that one.

  /// The origin of the v2 API this build talks to (`scheme://host:port`),
  /// or null when none is configured.
  String? get _currentOrigin {
    final override = _apiOriginOverride;
    return override != null ? override() : _configuredOrigin;
  }

  late final String? _configuredOrigin = originOf(Config.apiV2BaseUrl);

  /// The origin of [url] in one spelling: lower-case scheme and host, and
  /// the port always written (the scheme's own when the URL names none).
  /// Null when [url] has no host.
  @visibleForTesting
  static String? originOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty || !uri.hasScheme) return null;
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';
  }

  /// Where a vault whose record names the backend [recorded] stands to the
  /// backend this build talks to.
  _VaultOrigin _originOfRecord(String? recorded) {
    final current = _currentOrigin;
    if (current == null) return _VaultOrigin.elsewhere;
    if (recorded == null) return _VaultOrigin.unproven;
    return recorded == current ? _VaultOrigin.here : _VaultOrigin.elsewhere;
  }

  /// The first Android version whose phone backup can be end-to-end
  /// encrypted and which has passkeys (Android 9). Below it a vault has
  /// nothing to be opened with.
  static const _minAndroidSdk = 28;

  /// Read whether the phone backup that carries this device's platform
  /// entries is end-to-end encrypted, and bring the entries in line with the
  /// answer: see [PlatformBackupGuard]. Called whenever the app comes
  /// forward, and by this class before it writes an entry. Never throws.
  Future<PlatformBackupStatus> checkPlatformBackup() => _backup.check();

  /// What the last [checkPlatformBackup] found, for the screens that show it.
  ValueNotifier<PlatformBackupStatus> get platformBackup => _backup.status;

  /// The user was offered a replacement of the sign-in keys an unprotected
  /// backup may have held. Shown once.
  Future<void> markKeyReplacementOffered() => _backup.markReplacementOffered();

  /// The user chose to leave the keys of [vaultId] (or of every vault) as
  /// they are after an unprotected backup.
  Future<void> dismissBackupExposure([String? vaultId]) =>
      _backup.dismissExposure(vaultId);

  /// Whether a platform slot can be made on this device now. The backup's
  /// encryption state is read first, so that an entry is never written while
  /// the entries already here are in a backup that lost its encryption.
  Future<bool> _platformSlotWritable() async {
    await _backup.check();
    return _platform.isAvailable();
  }

  /// How long a platform entry is left alone after it was written, whatever
  /// the vault says. A device writes its entry BEFORE the vault write that
  /// makes the slot live, and on iOS the entry syncs to the user's other
  /// devices at once — where a sweep against a vault record read a moment
  /// earlier would see an entry of no slot and delete it, everywhere.
  static const sweepGrace = Duration(minutes: 10);

  /// How old the platform entry of an unconfirmed vault creation must be
  /// before [sweepAbandonedCreates] asks whether the vault exists.
  static const abandonedCreateAge = Duration(hours: 24);

  /// The least time between two status reads of one vault.
  static const statusInterval = Duration(minutes: 15);

  /// How far apart two "not found" answers for a linked vault must be before
  /// the second is acted on. See [checkStatus].
  static const notFoundConfirmAge = Duration(hours: 24);

  /// How long the platform entries of a vault are kept after its wallet was
  /// unlinked on a "not found" answer, and how often the vault is asked
  /// about meanwhile. See [checkRetired].
  static const retiredEntriesAge = Duration(days: 30);
  static const retiredCheckInterval = Duration(hours: 24);

  /// Bumped whenever this device's copy of a vault record changes, so the
  /// screens and banners that read it can refresh.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  String get _rpId => Config.passkeyRpId;

  /// Whether this device can add or use a passkey slot.
  Future<bool> passkeysAvailable() async =>
      _rpId.isNotEmpty && await _passkeys.isSupported();

  Future<bool> platformSlotAvailable() => _platform.isAvailable();

  // ---------------------------------------------------------------------------
  // Unlock
  // ---------------------------------------------------------------------------

  /// Open [vault] with a slot this device can use: the platform slot first
  /// (no prompt), then a passkey.
  ///
  /// Throws [SocialVaultUnlockException] when no slot works here, and lets a
  /// [PasskeyPrfException] (cancel included) through.
  Future<UnlockedSocialVault> unlock(api.SocialVault vault) async {
    final viaPlatform = await _unlockWithPlatformSlot(vault);
    if (viaPlatform != null) return viaPlatform;

    final candidates = passkeyCandidates(vault);
    final passkeysHere = await passkeysAvailable();
    if (candidates.isEmpty || !passkeysHere) {
      throw SocialVaultUnlockException(
        hasPasskeySlots: vault.slots.any(
          (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
        ),
        passkeysSupportedHere: passkeysHere,
      );
    }
    final result = await _passkeys.authenticate(
      rpId: _rpId,
      candidates: [
        for (final c in candidates)
          PasskeyPrfCandidate(credentialId: c.credentialId!, salt: _salt(c)),
      ],
    );
    final answered = SocialVaultCrypto.canonicalCredentialId(
      result.credentialId,
    );
    final slot = candidates.firstWhereOrNull(
      (s) =>
          SocialVaultCrypto.canonicalCredentialId(s.credentialId!) == answered,
    );
    if (slot == null) {
      throw const SocialVaultCryptoException('passkey matches no slot');
    }
    final dataKey = await SocialVaultCrypto.unwrapDataKey(
      vaultId: vault.vaultId,
      slotId: slot.slotId,
      kind: SocialVaultSlotKind.passkeyPrf,
      slotSecret: result.output,
      wrapped: SocialVaultSealed.fromWire(
        nonce: slot.nonce,
        ciphertext: slot.wrappedKey,
      ),
    );
    return _open(vault, dataKey, slot.slotId);
  }

  /// The vault's passkey slots this build can evaluate, newest first.
  List<api.SocialVaultSlot> passkeyCandidates(api.SocialVault vault) => vault
      .slots
      .where(
        (s) =>
            s.kind == api.SocialVaultSlotKind.passkeyPrf &&
            s.rpId == _rpId &&
            s.credentialId != null &&
            s.prfSalt != null,
      )
      .toList()
      .reversed
      .toList();

  /// Try every platform entry this device can read for the vault — its own
  /// and any synced from the user's other devices — against the vault's live
  /// platform slots.
  Future<UnlockedSocialVault?> _unlockWithPlatformSlot(
    api.SocialVault vault,
  ) async {
    final List<PlatformSlotEntry> entries;
    try {
      entries = await _platform.readAll(vault.vaultId);
    } catch (e) {
      AppLogger.warn(_tag, 'platform slots unreadable: ${e.runtimeType}');
      return null;
    }
    for (final entry in entries) {
      final slot = vault.slots.firstWhereOrNull(
        (s) =>
            s.slotId == entry.slotId &&
            s.kind == api.SocialVaultSlotKind.platform,
      );
      if (slot == null) continue;
      final Uint8List dataKey;
      try {
        dataKey = await SocialVaultCrypto.unwrapDataKey(
          vaultId: vault.vaultId,
          slotId: slot.slotId,
          kind: SocialVaultSlotKind.platform,
          slotSecret: entry.secret,
          wrapped: SocialVaultSealed.fromWire(
            nonce: slot.nonce,
            ciphertext: slot.wrappedKey,
          ),
        );
      } on SocialVaultCryptoException catch (e) {
        AppLogger.warn(_tag, 'platform slot did not unwrap: ${e.message}');
        continue;
      }
      // Past the unwrap, a failure is the vault's, not the slot's.
      return _open(vault, dataKey, slot.slotId);
    }
    return null;
  }

  /// The ids of this device's readable platform entries for [vaultId].
  Future<Set<String>> localPlatformSlotIds(String vaultId) async {
    try {
      return {for (final e in await _platform.readAll(vaultId)) e.slotId};
    } catch (_) {
      return const {};
    }
  }

  Future<UnlockedSocialVault> _open(
    api.SocialVault vault,
    Uint8List dataKey,
    String slotId,
  ) async {
    // The public key the backend checks writes against must be the one this
    // data key derives — otherwise this is not the vault's data key, or the
    // record was tampered with, and no write from here would be accepted.
    final keyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: dataKey,
      vaultId: vault.vaultId,
    );
    if (await SocialVaultCrypto.vaultPublicKey(keyPair) !=
        vault.vaultPublicKey) {
      throw const SocialVaultCryptoException('vault public key mismatch');
    }
    final payload = await SocialVaultCrypto.openPayload(
      vaultId: vault.vaultId,
      dataKey: dataKey,
      sealed: SocialVaultSealed.fromWire(
        nonce: vault.payloadNonce,
        ciphertext: vault.payloadCiphertext,
      ),
    );
    return UnlockedSocialVault(
      vault: withDisplayLabels(vault),
      dataKey: dataKey,
      payload: payload,
      openedWithSlotId: slotId,
    );
  }

  // ---------------------------------------------------------------------------
  // Create
  // ---------------------------------------------------------------------------

  /// Create the vault for the identity behind [identityToken], holding
  /// [payload].
  ///
  /// The first slot is the platform slot where the platform offers one, and
  /// its secret is written to the platform store BEFORE the vault is created,
  /// so no vault can exist whose only slot secret was never saved. Without a
  /// platform slot the first slot is a passkey ([userName] labels it in the
  /// platform's passkey list). With neither, it throws
  /// [SocialVaultUnlockException] and creates nothing.
  ///
  /// A `vault_exists` refusal (another device won the first-sign-in race)
  /// surfaces as [SocialVaultApiException]; the caller opens that vault.
  Future<UnlockedSocialVault> create({
    required String identityToken,
    required SocialVaultPayload payload,
    required String userName,
  }) async {
    // Exactly what gets sealed, so the phrase kept on this device is
    // byte-for-byte what every other client will read out of the vault.
    payload = SocialVaultPayload.fromJsonString(
      SocialVaultCrypto.canonicalPayloadJson(payload),
    );
    final vaultId = SocialVaultCrypto.newVaultId();
    final dataKey = SocialVaultCrypto.newDataKey();
    final keyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: dataKey,
      vaultId: vaultId,
    );
    final sealed = await SocialVaultCrypto.sealPayload(
      vaultId: vaultId,
      dataKey: dataKey,
      payload: payload,
    );

    final slots = <api.SocialVaultNewSlot>[];
    PlatformSlotEntry? platformEntry;
    // From here until this returns, the vault is one this device is creating:
    // nothing may sweep its platform entry.
    _creating.add(vaultId);
    try {
      if (await _platformSlotWritable()) {
        platformEntry = await _newPlatformEntry(vaultId);
        if (platformEntry != null) {
          slots.add(await _platformSlot(vaultId, dataKey, platformEntry));
          // Until the backend answers, this creation is unconfirmed: the
          // entry may be the only slot secret of a vault that exists, or the
          // leftover of one that never will. The record, with the data key
          // kept beside it, is what lets a later launch ask the backend
          // which (see [sweepAbandonedCreates]) instead of guessing.
          await _storage.storeSocialVaultDataKey(
            vaultId,
            SocialVaultCrypto.base64UrlNoPad(dataKey),
          );
          await _recordPendingCreate(vaultId, platformEntry);
        }
      }
      if (slots.isEmpty) {
        if (!await passkeysAvailable()) {
          throw SocialVaultUnlockException(
            hasPasskeySlots: false,
            passkeysSupportedHere: false,
            creating: true,
            platformStoreFull: _platformStoreFull,
            platformTooOld: await _androidTooOld(),
          );
        }
        slots.add(
          await _passkeySlot(
            vaultId: vaultId,
            dataKey: dataKey,
            userName: userName,
            existing: const [],
          ),
        );
      }

      final api.SocialVault vault;
      try {
        vault = _recordOf(
          vaultId,
          await _api.create(
            api.SocialVaultCreateRequest(
              identityToken: identityToken,
              vaultId: vaultId,
              payloadNonce: sealed.nonceWire,
              payloadCiphertext: sealed.ciphertextWire,
              vaultPublicKey: await SocialVaultCrypto.vaultPublicKey(keyPair),
              slots: slots,
            ),
          ),
        );
      } on SocialVaultApiException catch (e) {
        // Only a refusal by the backend itself frees the platform entry
        // ([SocialVaultApiException.refusedByBackend]). Without an answer,
        // with one that cannot be read, or with one that something else gave
        // (a 404 or any other 4xx with no code of the backend's on it) the
        // vault may exist, and the entry may be its only slot secret: it
        // stays, recorded as unconfirmed.
        if (platformEntry != null && e.refusedByBackend) {
          await _deletePlatformEntryQuietly(vaultId, platformEntry.slotId);
          await _dropPendingCreate(vaultId, dataKey);
        }
        rethrow;
      }
      // Confirmed. The data key goes back out until the caller keeps the
      // wallet ([persist] stores it again): a wallet that then fails to be
      // stored must not leave a key behind.
      if (platformEntry != null) await _dropPendingCreate(vaultId, dataKey);
      return UnlockedSocialVault(
        vault: vault,
        dataKey: dataKey,
        payload: payload,
        openedWithSlotId: slots.first.slotId,
      );
    } finally {
      _creating.remove(vaultId);
    }
  }

  /// Vaults this device is creating right now.
  final Set<String> _creating = <String>{};

  // ---------------------------------------------------------------------------
  // Unconfirmed creations
  // ---------------------------------------------------------------------------

  Future<List<_PendingCreate>> _pendingCreates() async {
    try {
      final raw = await _storage.loadSocialVaultPendingCreates();
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final item in jsonDecode(raw) as List)
          ?_PendingCreate.tryParse(item),
      ];
    } catch (e) {
      AppLogger.warn(_tag, 'pending creations unreadable: ${e.runtimeType}');
      return [];
    }
  }

  Future<void> _storePendingCreates(List<_PendingCreate> records) async {
    try {
      await _storage.storeSocialVaultPendingCreates(
        jsonEncode([for (final r in records) r.toJson()]),
      );
    } catch (e) {
      AppLogger.warn(_tag, 'pending creations not saved: ${e.runtimeType}');
    }
  }

  static const _pendingCreatesRecord = 'pending-creates';

  /// Take [vaultId] out of the journal of unconfirmed creations. Answers
  /// whether it was in it. The journal is one record for every vault, so
  /// its changes go one at a time.
  Future<bool> _removePendingCreate(String vaultId) =>
      _records.run(_pendingCreatesRecord, () async {
        final records = await _pendingCreates();
        if (!records.any((r) => r.vaultId == vaultId)) return false;
        await _storePendingCreates(
          records.where((r) => r.vaultId != vaultId).toList(),
        );
        return true;
      });

  Future<void> _recordPendingCreate(String vaultId, PlatformSlotEntry entry) =>
      _records.run(
        _pendingCreatesRecord,
        () async => _storePendingCreates([
          ...(await _pendingCreates()).where((r) => r.vaultId != vaultId),
          _PendingCreate(
            vaultId: vaultId,
            slotId: entry.slotId,
            createdAt: entry.createdAt ?? _clock().toUtc(),
            // The backend the creation was sent to: the only one whose "not
            // found" says the vault was never made.
            apiOrigin: _currentOrigin,
          ),
        ]),
      );

  /// Forget that [vaultId]'s creation was unconfirmed, keeping its data key:
  /// a wallet on this device uses the vault.
  Future<void> _settlePendingCreate(String vaultId) =>
      _removePendingCreate(vaultId);

  /// Forget that [vaultId]'s creation was unconfirmed, and [dataKey], the
  /// data key that was kept for asking about it.
  ///
  /// Only that key: if another one is stored by now, a sign-in has opened
  /// the vault and kept the wallet's key in the meantime, and it stays.
  Future<void> _dropPendingCreate(String vaultId, List<int> dataKey) async {
    if (!await _removePendingCreate(vaultId)) return;
    try {
      await _deleteDataKeyIfStill(vaultId, dataKey);
    } catch (e) {
      AppLogger.warn(_tag, 'pending data key not deleted: ${e.runtimeType}');
    }
  }

  /// Delete this device's data key for [vaultId] if it is still [dataKey].
  /// Answers whether it was deleted.
  ///
  /// Every delete of a data key on evidence goes through this: the evidence
  /// is about one key (the one a request was signed with, the one a journal
  /// kept), and by the time it is acted on another may be stored.
  Future<bool> _deleteDataKeyIfStill(String vaultId, List<int> dataKey) async {
    final stored = await _storage.loadSocialVaultDataKey(vaultId);
    if (stored != SocialVaultCrypto.base64UrlNoPad(dataKey)) return false;
    await _storage.deleteSocialVaultDataKey(vaultId);
    return true;
  }

  /// Clean up after vault creations this device started and never saw
  /// confirmed (the request got no answer, or the app died mid-create), so
  /// their platform entries do not hold one of Block Store's 16 places for
  /// good.
  ///
  /// Only such an entry is ever a candidate. An entry this device has no
  /// record of creating is left alone however old it is and whether or not a
  /// wallet here uses its vault: it may be the only slot secret of a wallet
  /// that was removed from this device, of one being restored after a
  /// reinstall, or (on iOS, where entries sync) of a wallet on another
  /// device.
  ///
  /// A candidate is deleted only on proof: once it is [abandonedCreateAge]
  /// old, no wallet in [referencedVaultIds] uses its vault and the vault is
  /// not being created right now, a status read signed with the data key
  /// kept for it must answer that the vault does not exist — with the
  /// backend's own "no such vault" code, and from the backend the creation
  /// was sent to. A record that names another backend is not asked about at
  /// all; one that names none (it was written before the backend was recorded)
  /// is asked about, but only an answer that the vault exists is acted on.
  /// A vault that does exist keeps its entry — the next sign-in opens it.
  Future<void> sweepAbandonedCreates({
    required Set<String> referencedVaultIds,
  }) async {
    final now = _clock();
    for (final record in await _pendingCreates()) {
      final vaultId = record.vaultId;
      if (_creating.contains(vaultId)) continue;
      if (referencedVaultIds.contains(vaultId)) {
        // A wallet here uses the vault, so its creation is settled; the data
        // key is the wallet's now and stays.
        await _settlePendingCreate(vaultId);
        continue;
      }
      if (now.difference(record.createdAt).abs() < abandonedCreateAge) continue;
      final origin = _originOfRecord(record.apiOrigin);
      if (origin == _VaultOrigin.elsewhere) continue;
      try {
        await _operations.run(vaultId, () async {
          // Looked at again now that nothing else is working on this vault:
          // [referencedVaultIds] was gathered before the wait, and a sign-in
          // that was ahead in the queue has settled the creation and made
          // the stored key the wallet's.
          if (!(await _pendingCreates()).any((r) => r.vaultId == vaultId)) {
            return;
          }
          final dataKey = await loadDataKey(vaultId);
          if (dataKey == null) return;
          try {
            _recordOf(
              vaultId,
              await _api.status(
                vaultKey: await SocialVaultCrypto.vaultKeyPair(
                  dataKey: dataKey,
                  vaultId: vaultId,
                ),
                vaultId: vaultId,
                revision: 1,
              ),
            );
            // It exists: its entry is a live slot secret.
            await _dropPendingCreate(vaultId, dataKey);
          } on SocialVaultApiException catch (e) {
            if (e.error != SocialVaultApiError.notFound) return;
            if (origin != _VaultOrigin.here) return;
            await _deletePlatformEntryQuietly(vaultId, record.slotId);
            await _dropPendingCreate(vaultId, dataKey);
          }
        });
      } catch (e) {
        AppLogger.warn(_tag, 'abandoned create not checked: ${e.runtimeType}');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Slots
  // ---------------------------------------------------------------------------

  /// Give this device a platform slot of its own when it has none that is
  /// live — after opening a vault with a passkey on a new device, say.
  /// Returns the vault after the write (or unchanged). Best
  /// effort for callers: the vault is already open either way.
  Future<api.SocialVault> ensurePlatformSlot(
    api.SocialVault vault,
    Uint8List dataKey,
  ) async {
    if (!await _platformSlotWritable()) return vault;
    final local = await localPlatformSlotIds(vault.vaultId);
    if (vault.slots.any(
      (s) =>
          s.kind == api.SocialVaultSlotKind.platform &&
          local.contains(s.slotId),
    )) {
      return vault;
    }
    final entry = await _newPlatformEntry(vault.vaultId);
    if (entry == null) return vault;
    try {
      return await _write(
        vault,
        dataKey,
        (keyPair, revision) async => _api.addSlot(
          vaultKey: keyPair,
          vaultId: vault.vaultId,
          revision: revision,
          slot: await _platformSlot(vault.vaultId, dataKey, entry),
        ),
        ownSlotIds: {entry.slotId},
      );
    } on SocialVaultApiException catch (e) {
      // A refusal by the backend itself means the slot was never added: its
      // entry would open nothing. Without an answer — or with a 4xx that
      // carries no code of the backend's, which a proxy or another backend
      // gives — the slot may exist, so keep it.
      if (e.refusedByBackend) {
        await _deletePlatformEntryQuietly(vault.vaultId, entry.slotId);
      }
      rethrow;
    }
  }

  /// A new platform entry for [vaultId], saved add-only before any slot
  /// refers to it, or null when the store refused it (full, or failing).
  Future<PlatformSlotEntry?> _newPlatformEntry(String vaultId) async {
    final entry = PlatformSlotEntry(
      slotId: SocialVaultCrypto.newSlotId(),
      secret: SocialVaultCrypto.randomBytes(SocialVaultCrypto.keyLength),
      createdAt: _clock().toUtc(),
    );
    try {
      final cloudBacked = await _platform.add(vaultId, entry);
      _platformStoreFull = false;
      // Whether it went into the cloud backup or stayed on this device is
      // what the next backup check starts from.
      await _backup.recordWrite(
        vaultId,
        entry.slotId,
        cloudBacked: cloudBacked,
      );
      return entry;
    } on PlatformException catch (e) {
      _platformStoreFull = e.code == 'store_full';
      AppLogger.warn(_tag, 'platform slot not saved: ${e.code}');
      return null;
    } catch (e) {
      AppLogger.warn(_tag, 'platform slot not saved: ${e.runtimeType}');
      return null;
    }
  }

  /// Whether the last platform entry was refused because the store is full
  /// (Block Store keeps at most 16 entries per app).
  bool _platformStoreFull = false;

  /// Register a passkey and add it as a slot.
  Future<api.SocialVault> addPasskeySlot(
    api.SocialVault vault,
    Uint8List dataKey, {
    required String userName,
  }) async {
    final slot = await _passkeySlot(
      vaultId: vault.vaultId,
      dataKey: dataKey,
      userName: userName,
      existing: vault.slots,
    );
    return _write(
      vault,
      dataKey,
      (keyPair, revision) => _api.addSlot(
        vaultKey: keyPair,
        vaultId: vault.vaultId,
        revision: revision,
        slot: slot,
      ),
      ownSlotIds: {slot.slotId},
    );
  }

  /// Remove [slotId]. When it is this device's platform slot, the local
  /// platform entry goes with it (it would unwrap nothing any more).
  Future<api.SocialVault> removeSlot(
    api.SocialVault vault,
    Uint8List dataKey,
    String slotId,
  ) async {
    final updated = await _write(
      vault,
      dataKey,
      (keyPair, revision) => _api.removeSlot(
        vaultKey: keyPair,
        vaultId: vault.vaultId,
        revision: revision,
        slotId: slotId,
      ),
    );
    // The slot is gone server-side, so its local entry (if this device holds
    // it) can go too.
    if ((await localPlatformSlotIds(vault.vaultId)).contains(slotId)) {
      await _deletePlatformEntryQuietly(vault.vaultId, slotId);
    }
    return updated;
  }

  /// The longest slot label the backend keeps, counted as it counts them:
  /// in Unicode code points (`String.runes`), not in the characters a reader
  /// sees. One flag emoji is two.
  static const maxSlotLabelLength = 64;

  /// [label] as it may be stored: the one rule for a sign-in key's name,
  /// for the field that takes it and for [renameSlot] alike.
  ///
  /// A label is display text that every device of the wallet draws inside
  /// its own rows and sentences. So it is one line of plain text: a line
  /// break or tab becomes a space, every other control character and every
  /// character that changes the direction the text around it is drawn in is
  /// left out (see [_withoutControls]), and the ends are trimmed. What is
  /// left may be empty (the key then reads as its kind) and is at most
  /// [maxSlotLabelLength] code points: a longer one throws
  /// [SocialVaultLabelException], which carries the length for a message.
  static String normalizeSlotLabel(String label) {
    final clean = _withoutControls(label).trim();
    final length = clean.runes.length;
    if (length > maxSlotLabelLength) throw SocialVaultLabelException(length);
    return clean;
  }

  /// [label], as read from the backend, as it may be drawn: cleaned like
  /// [normalizeSlotLabel] does, and null when nothing is left. Another
  /// client, or an earlier build, may have stored one this app would not.
  static String? displaySlotLabel(String? label) {
    if (label == null) return null;
    final clean = _withoutControls(label).trim();
    return clean.isEmpty ? null : clean;
  }

  /// [vault] with every slot label made safe to draw ([displaySlotLabel]).
  /// Every record this class hands out or keeps has been through it.
  static api.SocialVault withDisplayLabels(api.SocialVault vault) {
    if (vault.slots.every((s) => displaySlotLabel(s.label) == s.label)) {
      return vault;
    }
    return api.SocialVault(
      vaultId: vault.vaultId,
      revision: vault.revision,
      payloadNonce: vault.payloadNonce,
      payloadCiphertext: vault.payloadCiphertext,
      vaultPublicKey: vault.vaultPublicKey,
      slots: [
        for (final s in vault.slots)
          api.SocialVaultSlot(
            createdAt: s.createdAt,
            slotId: s.slotId,
            kind: s.kind,
            nonce: s.nonce,
            wrappedKey: s.wrappedKey,
            prfSalt: s.prfSalt,
            credentialId: s.credentialId,
            rpId: s.rpId,
            label: displaySlotLabel(s.label),
          ),
      ],
      pendingDeletion: vault.pendingDeletion,
      createdAt: vault.createdAt,
      updatedAt: vault.updatedAt,
    );
  }

  /// [text] without the characters a label never carries: C0 and C1
  /// controls, the bidirectional controls (U+061C, U+200E, U+200F,
  /// U+202A–U+202E, U+2066–U+2069) and unpaired surrogates. Line breaks and
  /// tabs become a space, so words pasted on two lines do not run together.
  static String _withoutControls(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      final lineBreakOrTab =
          (rune >= 0x09 && rune <= 0x0D) ||
          rune == 0x85 ||
          rune == 0x2028 ||
          rune == 0x2029;
      final dropped =
          rune <= 0x1F ||
          (rune >= 0x7F && rune <= 0x9F) ||
          rune == 0x061C ||
          rune == 0x200E ||
          rune == 0x200F ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          (rune >= 0xD800 && rune <= 0xDFFF);
      if (lineBreakOrTab) {
        out.write(' ');
      } else if (!dropped) {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Rename [slotId]: [label], cleaned by [normalizeSlotLabel], replaces its
  /// label, and an empty one clears it (the key then reads as its kind).
  /// Only the label changes, so nothing else about the slot or this
  /// device's entries is touched.
  ///
  /// Throws [SocialVaultLabelException], having sent nothing, for a label
  /// that is too long.
  Future<api.SocialVault> renameSlot(
    api.SocialVault vault,
    Uint8List dataKey,
    String slotId,
    String label,
  ) async {
    final clean = normalizeSlotLabel(label);
    return _write(
      vault,
      dataKey,
      (keyPair, revision) => _api.renameSlot(
        vaultKey: keyPair,
        vaultId: vault.vaultId,
        revision: revision,
        slotId: slotId,
        label: clean,
      ),
    );
  }

  /// What removing [slotId] by rotation keeps and drops, for the user to
  /// confirm before anything changes.
  ///
  /// A rotation replaces the data key and vault key, so every slot must be
  /// re-wrapped — and this device can re-wrap only what it can re-create now:
  /// a new platform slot of its own, and each passkey the user confirms here
  /// (one prompt per passkey). Everything else is dropped: [slotId] itself,
  /// other devices' platform slots, and passkeys this device cannot use.
  Future<SocialVaultRemovalPlan> planRemoval(
    api.SocialVault vault,
    String slotId,
  ) async {
    final passkeysHere = await passkeysAvailable();
    final reassertable = <api.SocialVaultSlot>[];
    final dropped = <api.SocialVaultSlot>[];
    for (final slot in vault.slots) {
      if (slot.slotId == slotId) {
        dropped.add(slot);
      } else if (passkeysHere && passkeyCandidates(vault).contains(slot)) {
        reassertable.add(slot);
      } else {
        dropped.add(slot);
      }
    }
    return SocialVaultRemovalPlan(
      removing: vault.slots.firstWhere((s) => s.slotId == slotId),
      newPlatformSlot: await _platformSlotWritable(),
      passkeysToConfirm: reassertable,
      dropped: dropped,
    );
  }

  /// Carry out [plan]: new data key and vault key, the same payload sealed
  /// again, and only the slots this device re-creates now. Signed by the
  /// current vault key. The new data key replaces the old one in
  /// MnemonicVault only after the backend accepted the rotation, and the
  /// platform entries of dropped slots are deleted only then.
  ///
  /// A passkey the user cancels or cannot produce is dropped, as the plan
  /// said. If nothing at all could be kept, nothing is sent: the vault would
  /// open nowhere.
  ///
  /// The wallet's own keys do not change. A device that already opened the
  /// wallet keeps them; the rotation only stops dropped slots from opening
  /// the vault on new devices.
  Future<SocialVaultRotation> rotateRemoving({
    required api.SocialVault vault,
    required Uint8List dataKey,
    required SocialVaultRemovalPlan plan,
  }) async {
    final payload = await SocialVaultCrypto.openPayload(
      vaultId: vault.vaultId,
      dataKey: dataKey,
      sealed: SocialVaultSealed.fromWire(
        nonce: vault.payloadNonce,
        ciphertext: vault.payloadCiphertext,
      ),
    );
    final newDataKey = SocialVaultCrypto.newDataKey();
    final slots = <api.SocialVaultNewSlot>[];
    final unconfirmed = <api.SocialVaultSlot>[];

    for (final old in plan.passkeysToConfirm) {
      final salt = SocialVaultCrypto.randomBytes(SocialVaultCrypto.keyLength);
      final PasskeyPrfResult result;
      try {
        result = await _passkeys.authenticate(
          rpId: _rpId,
          candidates: [
            PasskeyPrfCandidate(credentialId: old.credentialId!, salt: salt),
          ],
        );
      } on PasskeyPrfException catch (e) {
        AppLogger.info(
          _tag,
          'passkey not confirmed (${e.error.name}): dropped',
        );
        unconfirmed.add(old);
        continue;
      }
      if (SocialVaultCrypto.canonicalCredentialId(result.credentialId) !=
          SocialVaultCrypto.canonicalCredentialId(old.credentialId!)) {
        // Another passkey answered: its PRF output is not this slot's, so the
        // slot is dropped rather than re-created under the wrong passkey.
        AppLogger.warn(_tag, 'a different passkey answered: slot dropped');
        unconfirmed.add(old);
        continue;
      }
      final slotId = SocialVaultCrypto.newSlotId();
      final wrapped = await SocialVaultCrypto.wrapDataKey(
        vaultId: vault.vaultId,
        slotId: slotId,
        kind: SocialVaultSlotKind.passkeyPrf,
        slotSecret: result.output,
        dataKey: newDataKey,
      );
      slots.add(
        api.SocialVaultNewSlot(
          slotId: slotId,
          kind: api.SocialVaultSlotKind.passkeyPrf,
          nonce: wrapped.nonceWire,
          wrappedKey: wrapped.ciphertextWire,
          prfSalt: SocialVaultCrypto.base64UrlNoPad(salt),
          credentialId: SocialVaultCrypto.canonicalCredentialId(
            old.credentialId!,
          ),
          rpId: _rpId,
          label: old.label,
        ),
      );
    }

    PlatformSlotEntry? newEntry;
    // Asked again, not taken from the plan: the user confirmed and
    // re-authenticated in between, and the backup's state is read before
    // every entry write.
    if (plan.newPlatformSlot && await _platformSlotWritable()) {
      newEntry = await _newPlatformEntry(vault.vaultId);
      if (newEntry != null) {
        slots.add(await _platformSlot(vault.vaultId, newDataKey, newEntry));
      }
    }
    if (slots.isEmpty) {
      throw SocialVaultUnlockException(
        hasPasskeySlots: false,
        passkeysSupportedHere: false,
        creating: true,
        platformStoreFull: plan.newPlatformSlot && _platformStoreFull,
      );
    }

    final newKeyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: newDataKey,
      vaultId: vault.vaultId,
    );
    final sealed = await SocialVaultCrypto.sealPayload(
      vaultId: vault.vaultId,
      dataKey: newDataKey,
      payload: payload,
    );
    final newPublicKey = await SocialVaultCrypto.vaultPublicKey(newKeyPair);
    final currentKeyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: dataKey,
      vaultId: vault.vaultId,
    );
    // From the request to the new key and record being stored, nothing else
    // works on this vault: a status read signed with the old key must not
    // have its answer acted on once the new key is the stored one.
    final rotated = await _operations.run(vault.vaultId, () async {
      final api.SocialVault rotated;
      try {
        rotated = _recordOf(
          vault.vaultId,
          await _api.rotate(
            currentVaultKey: currentKeyPair,
            request: api.SocialVaultRotateRequest(
              vaultId: vault.vaultId,
              revision: vault.revision,
              payloadNonce: sealed.nonceWire,
              payloadCiphertext: sealed.ciphertextWire,
              vaultPublicKey: newPublicKey,
              slots: slots,
            ),
          ),
        );
      } on SocialVaultApiException catch (e) {
        // A conflict's vault counts only when it is this vault's record.
        final conflict = e is SocialVaultConflictException
            ? _recordOfOrNull(vault.vaultId, e.vault)
            : null;
        // Stale only on evidence that the vault key changed. A refused
        // timestamp or a replay says nothing of the kind: see [_write].
        final stale =
            e.error == SocialVaultApiError.signatureRejected ||
            (conflict != null &&
                conflict.vaultPublicKey !=
                    await SocialVaultCrypto.vaultPublicKey(currentKeyPair));
        if (conflict != null) await _observe(conflict);
        // Refused by the backend itself: the new entry belongs to no slot.
        // Without an answer, with one that cannot be read, or with a 4xx
        // that carries no code of the backend's, the rotation may have
        // happened, so it stays.
        if (newEntry != null && e.refusedByBackend) {
          await _deletePlatformEntryQuietly(vault.vaultId, newEntry.slotId);
        }
        if (stale) {
          await _dropStaleDataKey(vault.vaultId, dataKey);
          throw SocialVaultStaleKeyException(vault.vaultId);
        }
        if (e is SocialVaultConflictException && conflict == null) {
          throw _notThisVault;
        }
        rethrow;
      }

      // Accepted: the new data key replaces the old one.
      await _storage.storeSocialVaultDataKey(
        vault.vaultId,
        SocialVaultCrypto.base64UrlNoPad(newDataKey),
      );
      // Every slot of the rotated vault was made here, just now.
      await _updateCache(
        rotated,
        ownSlotIds: {for (final s in slots) s.slotId},
      );
      // What an unprotected phone backup held for this vault wrapped the old
      // data key, which opens nothing from now on. That is all a rotation
      // does about it: the phrase inside is the same one, so it undoes
      // nothing for a backup that was already read and used.
      await _backup.keysReplaced(vault.vaultId);
      return rotated;
    });
    // The entries of the slots that are gone are swept (past the grace
    // period, like any other sweep), against the record the rotation itself
    // just returned.
    await _sweepAgainst(rotated);
    return SocialVaultRotation(
      vault: rotated,
      unconfirmedPasskeys: unconfirmed,
    );
  }

  /// Delete this device's platform entries for the slots of [vaultId] that
  /// are no longer live (removed or rotated out elsewhere). Called whenever
  /// a vault is opened, so stale entries do not pile up — Block Store holds
  /// 16.
  ///
  /// The slot list it sweeps against is read now, with a status read signed
  /// by [dataKey] — never taken from a record the caller has been holding.
  /// A sign-in fetches the record and then waits on the user (a passkey
  /// sheet, for as long as they like); meanwhile another device can add a
  /// slot, and on a shared iCloud Keychain its entry is here before this
  /// device hears of the slot. Swept against the older list, that entry
  /// would be deleted on every device. When the record cannot be read now —
  /// offline, refused, under another key — nothing is swept: the next
  /// sign-in tries again.
  ///
  /// An entry younger than [sweepGrace] is never deleted, whatever the
  /// record lists: it may be the entry of a slot another device is adding
  /// right now (see [sweepGrace]). An entry with no creation time predates
  /// the field and is old.
  Future<void> sweepPlatformEntries(String vaultId, Uint8List dataKey) async {
    final api.SocialVault? current;
    try {
      current = await _operations.run(vaultId, () async {
        final keyPair = await SocialVaultCrypto.vaultKeyPair(
          dataKey: dataKey,
          vaultId: vaultId,
        );
        final record = await cached(vaultId);
        final vault = _recordOf(
          vaultId,
          await _api.status(
            vaultKey: keyPair,
            vaultId: vaultId,
            revision: record?.vault.revision ?? 1,
          ),
        );
        if (record != null && vault.revision < record.vault.revision) {
          // Older than the record this device already holds: the slot list
          // of an earlier state of the vault. A slot added since is missing
          // from it, and its entry would be swept as stale.
          return null;
        }
        await _observe(vault);
        // Under another key the record is real, but not one this caller's
        // key speaks for; the status reads deal with that.
        return vault.vaultPublicKey ==
                await SocialVaultCrypto.vaultPublicKey(keyPair)
            ? vault
            : null;
      });
    } catch (e) {
      AppLogger.info(_tag, 'entries not swept: ${e.runtimeType}');
      return;
    }
    if (current != null) await _sweepAgainst(current);
  }

  /// [sweepPlatformEntries] against [vault], which must be current: the
  /// answer to a signed read or write made just now.
  Future<void> _sweepAgainst(api.SocialVault vault) async {
    final live = {for (final s in vault.slots) s.slotId};
    final List<PlatformSlotEntry> entries;
    try {
      entries = await _platform.readAll(vault.vaultId);
    } catch (e) {
      AppLogger.warn(_tag, 'platform slots unreadable: ${e.runtimeType}');
      return;
    }
    final now = _clock();
    for (final entry in entries) {
      if (live.contains(entry.slotId)) continue;
      final createdAt = entry.createdAt;
      if (createdAt != null && now.difference(createdAt).abs() < sweepGrace) {
        continue;
      }
      await _deletePlatformEntryQuietly(vault.vaultId, entry.slotId);
    }
  }

  /// Delete every platform entry of [vaultId], on every device the platform
  /// syncs them to. Each one is a slot secret, and for a vault that still
  /// exists it may be the only thing that opens it — so this is called in two
  /// cases and no others: after the backend accepted a delete this device
  /// itself signed, and by [checkRetired] once the backend has said "not
  /// found" for the vault for [retiredEntriesAge] and says so again.
  ///
  /// Never on an `open` that returned no vault (that answer cannot tell a
  /// deleted vault from a sign-in with another account), and never on a
  /// single "not found": nothing can authenticate that answer, and it is the
  /// one a wrong backend gives for every vault at once.
  Future<void> forgetPlatformEntries(String vaultId) async {
    for (final local in await localPlatformSlotIds(vaultId)) {
      await _deletePlatformEntryQuietly(vaultId, local);
    }
  }

  /// Delete the vault on the backend with a signed delete. When the backend
  /// accepts it, the vault's platform entries are deleted too, everywhere the
  /// platform synced them ([SocialVaultDeletion.deleted]).
  ///
  /// When the backend answers that there is no such vault
  /// ([SocialVaultDeletion.notFound]) nothing is deleted: this device did
  /// not see a delete go through, and "not found" is as unverifiable here as
  /// anywhere. The caller unlinks the wallet, as the user asked, and keeps
  /// the entries the way a "not found" from a status read does.
  ///
  /// Either answer is believed only from the backend the vault is known to
  /// live on. "Deleted" has no body to check and "not found" is true on
  /// every other backend, and what follows either cannot be taken back (the
  /// entries, or the wallet's link). So when the cached record names no
  /// backend yet, a status read is made first, and it must show the vault
  /// here; when it names another one, or the read does not show the vault,
  /// nothing is sent and this throws a [SocialVaultApiException]
  /// ([SocialVaultApiError.unavailable]). Signing in again settles where the
  /// vault lives.
  ///
  /// This device's own copy (the data key, the phrase, the cached record) is
  /// NOT touched either way: the caller unlinks the wallet from the vault
  /// first and drops the copy after, so that a crash in between leaves a
  /// wallet still linked to a vault this device can still ask about.
  Future<SocialVaultDeletion> deleteVault(
    api.SocialVault vault,
    Uint8List dataKey,
  ) async {
    final vaultId = vault.vaultId;
    if (!await _livesHere(vaultId)) {
      await checkStatus(vaultId, force: true);
      if (!await _livesHere(vaultId)) {
        AppLogger.warn(_tag, 'vault not known to live on this backend');
        throw const SocialVaultApiException(SocialVaultApiError.unavailable);
      }
    }
    try {
      await _write(vault, dataKey, (keyPair, revision) async {
        await _api.delete(
          vaultKey: keyPair,
          vaultId: vaultId,
          revision: revision,
        );
        return vault;
      }, answersWithRecord: false);
    } on SocialVaultApiException catch (e) {
      if (e.error != SocialVaultApiError.notFound) rethrow;
      return SocialVaultDeletion.notFound;
    }
    await forgetPlatformEntries(vaultId);
    return SocialVaultDeletion.deleted;
  }

  /// Whether the cached record of [vaultId] names the backend this build
  /// talks to as the one that showed the vault exists.
  Future<bool> _livesHere(String vaultId) async =>
      _originOfRecord((await cached(vaultId))?.apiOrigin) == _VaultOrigin.here;

  /// [deleteVault] for [vaultId] with this device's data key. Answers
  /// [SocialVaultDeletion.noKey], deleting nothing, when this device holds
  /// no data key that still signs for the vault: without it no delete can be
  /// signed.
  ///
  /// The revision comes from the cached record, or starts at 1; a conflict
  /// answer carries the current one and the delete is re-signed for it.
  Future<SocialVaultDeletion> deleteVaultWithLocalKey(String vaultId) async {
    if (!await hasUsableDataKey(vaultId)) return SocialVaultDeletion.noKey;
    final dataKey = (await loadDataKey(vaultId))!;
    return deleteVault(await _vaultForWrite(vaultId, dataKey), dataKey);
  }

  /// What a write for [vaultId] starts from: the cached record, or — when
  /// this device has none — a placeholder at revision 1, which a conflict
  /// answer corrects.
  Future<api.SocialVault> _vaultForWrite(
    String vaultId,
    Uint8List dataKey,
  ) async {
    final cachedVault = (await cached(vaultId))?.vault;
    if (cachedVault != null) return cachedVault;
    return api.SocialVault(
      vaultId: vaultId,
      revision: 1,
      payloadNonce: '',
      payloadCiphertext: '',
      vaultPublicKey: await SocialVaultCrypto.vaultPublicKey(
        await SocialVaultCrypto.vaultKeyPair(
          dataKey: dataKey,
          vaultId: vaultId,
        ),
      ),
      slots: const [],
      pendingDeletion: null,
      createdAt: '',
      updatedAt: '',
    );
  }

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------

  /// When each vault's status was last read, by vault id.
  final Map<String, DateTime> _lastStatusRead = <String, DateTime>{};

  /// Read [vaultId]'s current record with a status read signed by this
  /// device's data key — no sign-in, no prompt — and act on what it shows:
  ///
  /// - the cached record takes the answer (which is also what feeds
  ///   [unseenSlots] and the pending-deletion warning);
  /// - a vault under another vault key, or a refused signature, drops this
  ///   device's stale data key ([SocialVaultStatus.staleKey]);
  /// - "not found" is not believed at once. The answer cannot be
  ///   authenticated — the backend is the only authority on what exists — and
  ///   it is exactly what a build pointed at the wrong backend, or a backend
  ///   restored from an older copy, answers for every vault. So the first one
  ///   is only written down ([SocialVaultStatus.unconfirmedGone]), and the
  ///   vault is reported gone ([SocialVaultStatus.gone]) only when a read at
  ///   least [notFoundConfirmAge] later says "not found" again. Any answer in
  ///   between that shows the vault exists — its record, a conflict, a
  ///   refused or replayed signature — starts the count over. Even then
  ///   nothing is deleted here: the caller unlinks the wallet and keeps its
  ///   platform entries ([retire]).
  ///
  /// "Not found" counts only as the backend's own coded answer (see
  /// [SocialVaultApiError.notFound]), and only from the backend the vault is
  /// known to live on:
  ///
  /// - a cached record that names **another backend** than the one this
  ///   build talks to (by origin: scheme, host and port) is not asked about
  ///   at all ([SocialVaultStatus.skipped]): on any backend but its own,
  ///   every vault is "not found". A sign-in, or a write the user makes,
  ///   that shows the vault on this one names it;
  /// - a record that names **no backend** (written before it was kept, or
  ///   no record at all) is asked about, and takes this backend from any
  ///   answer that shows the vault here — its record, or a signature the
  ///   backend checked against its key. A "not found" for it is dropped
  ///   ([SocialVaultStatus.failed]): nothing is written down, so it can
  ///   never add up to [SocialVaultStatus.gone].
  ///
  /// The answer must also be about this vault: a record with another id, or
  /// without what a record carries, is a failed read.
  ///
  /// It waits its turn behind any write on the same vault and reads this
  /// device's data key only then, so its answer is never about a key that a
  /// write has since replaced (see [_operations]).
  ///
  /// Skipped without a data key, and when the vault was read less than
  /// [statusInterval] ago unless [force]d. Never throws: being offline is
  /// normal, and every failure — a wrong clock included — changes nothing.
  Future<SocialVaultStatus> checkStatus(
    String vaultId, {
    bool force = false,
  }) async {
    try {
      return await _operations.run(
        vaultId,
        () => _readStatus(vaultId, force: force),
      );
    } catch (e) {
      AppLogger.info(_tag, 'status not read: ${e.runtimeType}');
      return SocialVaultStatus.failed;
    }
  }

  Future<SocialVaultStatus> _readStatus(
    String vaultId, {
    required bool force,
  }) async {
    final dataKey = await loadDataKey(vaultId);
    if (dataKey == null) return SocialVaultStatus.skipped;
    final record = await cached(vaultId);
    final origin = _originOfRecord(record?.apiOrigin);
    if (origin == _VaultOrigin.elsewhere) return SocialVaultStatus.skipped;
    final now = _clock();
    final last = _lastStatusRead[vaultId];
    if (!force && last != null && now.difference(last).abs() < statusInterval) {
      return SocialVaultStatus.skipped;
    }
    _lastStatusRead[vaultId] = now;
    final keyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: dataKey,
      vaultId: vaultId,
    );
    final api.SocialVault vault;
    try {
      vault = _recordOf(
        vaultId,
        await _api.status(
          vaultKey: keyPair,
          vaultId: vaultId,
          revision: record?.vault.revision ?? 1,
        ),
      );
    } on SocialVaultApiException catch (e) {
      switch (e.error) {
        case SocialVaultApiError.notFound:
          if (origin != _VaultOrigin.here) {
            // Nothing has shown the vault on this backend yet, so its "not
            // found" may be that of a backend that never had it.
            AppLogger.info(_tag, 'not found on a backend not yet proven');
            return SocialVaultStatus.failed;
          }
          return await _confirmedNotFound(vaultId)
              ? SocialVaultStatus.gone
              : SocialVaultStatus.unconfirmedGone;
        case SocialVaultApiError.signatureRejected:
          await _dropStaleDataKey(vaultId, dataKey, announce: true);
          return SocialVaultStatus.staleKey;
        case SocialVaultApiError.replayedSignature:
          // The backend checked the signature against the vault's key, so
          // the vault is there.
          await _seenHere(vaultId);
          return SocialVaultStatus.failed;
        default:
          AppLogger.info(_tag, 'status not read: ${e.error.name}');
          return SocialVaultStatus.failed;
      }
    }
    if (record != null && vault.revision < record.vault.revision) {
      // Older than the record this device already holds: a copy of the
      // vault from before its last change. The vault is there, and that is
      // all this says — the vault key it names may be one that was since
      // rotated away, so it is no evidence about the key in use now.
      await _seenHere(vaultId);
      AppLogger.info(_tag, 'status answer older than the cached record');
      return SocialVaultStatus.failed;
    }
    await _observe(vault);
    if (vault.vaultPublicKey !=
        await SocialVaultCrypto.vaultPublicKey(keyPair)) {
      await _dropStaleDataKey(vaultId, dataKey, announce: true);
      return SocialVaultStatus.staleKey;
    }
    return SocialVaultStatus.current;
  }

  /// Cancel [vaultId]'s pending deletion request with a write signed by this
  /// device's data key. Returns the vault after it.
  ///
  /// Throws [SocialVaultStaleKeyException] when this device holds no data
  /// key that signs for the vault, and whatever a write throws otherwise.
  Future<api.SocialVault> cancelDeletion(String vaultId) async {
    final dataKey = await loadDataKey(vaultId);
    if (dataKey == null) throw SocialVaultStaleKeyException(vaultId);
    return _write(
      await _vaultForWrite(vaultId, dataKey),
      dataKey,
      (keyPair, revision) => _api.cancelDeletion(
        vaultKey: keyPair,
        vaultId: vaultId,
        revision: revision,
      ),
    );
  }

  /// Send a signed write, retrying on a conflict under the same vault key.
  ///
  /// This device's data key is dropped only on evidence that the vault key
  /// changed: a conflict whose vault carries another public key, or a
  /// signature the backend could not verify (`invalid_vault_signature`). A
  /// refused timestamp (`stale_vault_timestamp`) is this device's clock, not
  /// its key — it is rethrown and nothing changes. A replay is retried by
  /// [SocialVaultApi] and likewise proves the key right.
  ///
  /// The whole of it — the request, its retries, and what its answer
  /// changes here — holds the vault's queue ([_operations]), so no status
  /// read crosses it. A vault record in the answer, or in a conflict, is
  /// taken only when it is this vault's ([_recordOf]); one that is not
  /// fails the write as a malformed answer, with nothing cached.
  ///
  /// [ownSlotIds] are slots this write adds: this device has seen them.
  /// [answersWithRecord] is false for the one write that answers with no
  /// record (the delete).
  Future<api.SocialVault> _write(
    api.SocialVault vault,
    Uint8List dataKey,
    Future<api.SocialVault> Function(SimpleKeyPair keyPair, int revision)
    send, {
    Set<String> ownSlotIds = const {},
    bool answersWithRecord = true,
  }) => _operations.run(vault.vaultId, () async {
    final vaultId = vault.vaultId;
    final keyPair = await SocialVaultCrypto.vaultKeyPair(
      dataKey: dataKey,
      vaultId: vaultId,
    );
    // Retry against a newer revision only while it is still the vault this
    // data key signs for: compare with the key it derives, not the cached one.
    final ours = await SocialVaultCrypto.vaultPublicKey(keyPair);
    final api.SocialVault updated;
    try {
      final answer = await SocialVaultApi.retryOnConflict(
        vaultId: vaultId,
        revision: vault.revision,
        vaultPublicKey: ours,
        attempt: (revision) => send(keyPair, revision),
      );
      updated = answersWithRecord ? _recordOf(vaultId, answer) : answer;
    } on SocialVaultConflictException catch (e) {
      final current = _recordOfOrNull(vaultId, e.vault);
      if (current == null) throw _notThisVault;
      await _observe(current);
      if (current.vaultPublicKey != ours) {
        await _dropStaleDataKey(vaultId, dataKey);
        throw SocialVaultStaleKeyException(vaultId);
      }
      rethrow;
    } on SocialVaultApiException catch (e) {
      if (e.error == SocialVaultApiError.signatureRejected) {
        await _dropStaleDataKey(vaultId, dataKey);
        throw SocialVaultStaleKeyException(vaultId);
      }
      rethrow;
    }
    if (answersWithRecord) await _updateCache(updated, ownSlotIds: ownSlotIds);
    return updated;
  });

  /// [vault], an answer from the backend about [vaultId], as a record this
  /// class may act on and keep: checked to be that vault's and to carry what
  /// a record carries ([SocialVaultApi.requireRecordOf], which throws a
  /// malformed-answer error otherwise), with its labels made safe to draw.
  static api.SocialVault _recordOf(String vaultId, api.SocialVault vault) =>
      withDisplayLabels(SocialVaultApi.requireRecordOf(vaultId, vault));

  static api.SocialVault? _recordOfOrNull(
    String vaultId,
    api.SocialVault vault,
  ) {
    try {
      return _recordOf(vaultId, vault);
    } on SocialVaultApiException {
      return null;
    }
  }

  /// A conflict whose vault is not the one the write named: not an answer
  /// about this vault, so nothing is taken from it.
  static const _notThisVault = SocialVaultApiException(
    SocialVaultApiError.malformedResponse,
    status: 409,
  );

  /// The data key [refused] no longer signs for the vault: another device
  /// rotated it, or this one did and lost the answer before keeping the new
  /// key. The key is dropped so nothing keeps signing with it; the wallet's
  /// chain keys and phrase stay, and the next sign-in reopens the vault
  /// through a slot and keeps the current data key.
  ///
  /// Called only on evidence that the vault key changed — an answer from
  /// the backend in hand: a vault record (from a conflict or a status read)
  /// under another public key, or an `invalid_vault_signature` — and never
  /// because a request was refused for its timestamp.
  ///
  /// The evidence is about [refused], so only [refused] is dropped: when
  /// another key is stored by now (this device rotated, or signed in again,
  /// since the request was signed), that one stays.
  ///
  /// [announce] is for a key found stale by a status read, which the user
  /// did not start and sees nothing of: the record is marked so that they
  /// are told once ([staleKeyNoticeDue]). A write the user made reports the
  /// stale key itself.
  Future<void> _dropStaleDataKey(
    String vaultId,
    List<int> refused, {
    bool announce = false,
  }) async {
    // Either way the backend knows the vault.
    await _seenHere(vaultId);
    if (!await _deleteDataKeyIfStill(vaultId, refused)) {
      AppLogger.info(_tag, 'a refused data key is no longer the stored one');
      return;
    }
    AppLogger.warn(_tag, 'data key no longer signs for the vault; dropped');
    if (announce) {
      await _editCache(
        vaultId,
        (previous) => previous?.copyWith(staleKeyNotice: true),
      );
    }
    changes.value++;
  }

  /// Whether this device's data key for [vaultId] was found stale by a
  /// status read and the user has not been told. See
  /// [markStaleKeyAnnounced].
  Future<bool> staleKeyNoticeDue(String vaultId) async =>
      (await cached(vaultId))?.staleKeyNotice ?? false;

  /// The user has been told that this device's key for [vaultId] was
  /// replaced elsewhere. Signing in again ([persist]) clears it too.
  Future<void> markStaleKeyAnnounced(String vaultId) => _editCache(
    vaultId,
    (previous) => previous == null || !previous.staleKeyNotice
        ? null
        : previous.copyWith(staleKeyNotice: false),
  );

  // ---------------------------------------------------------------------------
  // Vaults the backend says it does not have
  // ---------------------------------------------------------------------------
  //
  // A "not found" for a vault this device is linked to is the one answer that
  // could cost a wallet its backup if it were believed and wrong: acting on
  // it means deleting slot secrets, and on iOS that delete reaches every
  // device. Nothing can authenticate it, and it is what every vault gets from
  // a build pointed at the wrong backend or a backend restored from an older
  // copy. So it is acted on slowly and in steps that can be taken back:
  //
  // 1. two answers at least [notFoundConfirmAge] apart before the wallet is
  //    unlinked ([checkStatus]);
  // 2. the unlink keeps the platform entries and sets the data key aside
  //    ([retire]), so a sign-in, or the vault turning up again, links the
  //    wallet back;
  // 3. the entries are deleted only after [retiredEntriesAge] of "not
  //    found", on a fresh answer ([checkRetired]).
  //
  // And at every step "not found" means the backend's own coded answer,
  // from the backend the vault is known to live on (see "The backend a
  // vault lives on" above). A 404 of any other kind, or from any other
  // backend, is a failed read.

  Future<_MissingVaults> _missing() async {
    try {
      final raw = await _storage.loadSocialVaultMissing();
      if (raw == null || raw.isEmpty) return _MissingVaults();
      return _MissingVaults.fromJson(jsonDecode(raw));
    } catch (e) {
      AppLogger.warn(_tag, 'missing-vault record unreadable: ${e.runtimeType}');
      return _MissingVaults();
    }
  }

  static const _missingRecord = 'missing';

  /// Change what is written down about missing vaults. It is one record for
  /// every vault, so its changes go one at a time ([_records]): each reads
  /// the record as the one before left it, and nothing held across a
  /// request is written back over a newer one.
  ///
  /// A record that could not be saved is logged and otherwise ignored —
  /// except with [mustSave], for the one change something later depends on
  /// having been kept.
  Future<T> _editMissing<T>(
    T Function(_MissingVaults record) edit, {
    bool mustSave = false,
  }) => _records.run(_missingRecord, () async {
    final record = await _missing();
    final before = jsonEncode(record.toJson());
    final result = edit(record);
    final after = jsonEncode(record.toJson());
    if (after == before) return result;
    try {
      await _storage.storeSocialVaultMissing(after);
    } catch (e) {
      AppLogger.warn(_tag, 'missing-vault record not saved: ${e.runtimeType}');
      if (mustSave) rethrow;
    }
    return result;
  });

  /// Write down that the backend answered "not found" for [vaultId], and say
  /// whether that is the second such answer, at least [notFoundConfirmAge]
  /// after the first.
  Future<bool> _confirmedNotFound(String vaultId) {
    final now = _clock().toUtc();
    return _editMissing((record) {
      final first = record.firstNotFound[vaultId];
      // A first sighting — or a clock that went backwards, which leaves no
      // way to tell how long ago the first one was: count from now.
      if (first == null || now.isBefore(first)) {
        record.firstNotFound[vaultId] = now;
        return false;
      }
      return now.difference(first) >= notFoundConfirmAge;
    });
  }

  /// The backend showed that [vaultId] exists: an earlier "not found" for it
  /// counts for nothing.
  Future<void> _clearNotFound(String vaultId) =>
      _editMissing((record) => record.firstNotFound.remove(vaultId));

  /// The backend this build talks to showed that it has [vaultId] — with
  /// its record, or by checking a signature against its key. An earlier
  /// "not found" counts for nothing, and the cached record names this backend
  /// as the one the vault lives on.
  Future<void> _seenHere(String vaultId) async {
    await _clearNotFound(vaultId);
    final origin = _currentOrigin;
    await _editCache(
      vaultId,
      (previous) => previous == null || previous.apiOrigin == origin
          ? null
          : previous.copyWith(apiOrigin: origin),
    );
  }

  /// The wallet of [accountId] is being unlinked from [vaultId] because the
  /// backend said, twice and a day apart, that the vault does not exist — or
  /// said so to a delete the user asked for. Unlike after a delete the
  /// backend accepted, nothing of the vault's is destroyed:
  ///
  /// - its platform entries stay where they are, on this device and on every
  ///   device the platform syncs them to;
  /// - this device's data key is set aside (`storeSocialVaultRetiredKey`). To
  ///   the rest of the app the wallet holds no data key any more — the
  ///   caller drops the vault's own items with [forgetLocal] — but
  ///   [checkRetired] can still sign a status read with it;
  /// - the vault is written down with the time, the account, and what a
  ///   re-link needs ([identityId], [provider], the email hint).
  ///
  /// The record keeps the backend the vault was known to live on (the cached
  /// record's), which is the only one [checkRetired] believes a later "not
  /// found" from.
  ///
  /// [announced] is false while the user has yet to be told
  /// ([markRetiredAnnounced]). Repeatable: a second call for the same vault
  /// starts its clock again.
  Future<void> retire(
    String vaultId, {
    required String accountId,
    required String provider,
    String? identityId,
    bool announced = false,
  }) => _operations.run(vaultId, () async {
    final raw = await _storage.loadSocialVaultDataKey(vaultId);
    if (raw != null && raw.isNotEmpty) {
      await _storage.storeSocialVaultRetiredKey(vaultId, raw);
    }
    final now = _clock().toUtc();
    final previous = await cached(vaultId);
    await _editMissing((record) {
      record.firstNotFound.remove(vaultId);
      record.retired
        ..removeWhere((r) => r.vaultId == vaultId)
        ..add(
          RetiredSocialVault(
            vaultId: vaultId,
            accountId: accountId,
            provider: provider,
            identityId: identityId,
            emailHint: previous?.emailHint,
            apiOrigin: previous?.apiOrigin,
            unlinkedAt: now,
            lastCheckedAt: now,
            announced: announced,
          ),
        );
    });
  });

  /// The vaults wallets on this device were unlinked from on a "not found"
  /// answer, and whose platform entries are still kept.
  Future<List<RetiredSocialVault>> retiredVaults() async =>
      List.unmodifiable((await _missing()).retired);

  /// The user has been told that the wallet of the retired vault [vaultId]
  /// has no backup with the backend any more.
  Future<void> markRetiredAnnounced(String vaultId) =>
      _editRetired(vaultId, (retired) => retired.copyWith(announced: true));

  /// Replace the retired record of [vaultId], if there is one.
  Future<void> _editRetired(
    String vaultId,
    RetiredSocialVault Function(RetiredSocialVault retired) edit,
  ) => _editMissing((record) {
    final index = record.retired.indexWhere((r) => r.vaultId == vaultId);
    if (index >= 0) record.retired[index] = edit(record.retired[index]);
  });

  /// Stop keeping track of the retired vault [vaultId] and drop the data key
  /// set aside for it. Its platform entries are NOT touched: this is for a
  /// vault that is linked again, or whose wallet left this device — and an
  /// entry outlives both.
  Future<void> forgetRetired(String vaultId) async {
    await _editMissing(
      (record) => record.retired.removeWhere((r) => r.vaultId == vaultId),
    );
    try {
      await _storage.deleteSocialVaultRetiredKey(vaultId);
    } catch (e) {
      AppLogger.warn(_tag, 'retired data key not deleted: ${e.runtimeType}');
    }
  }

  // ---------------------------------------------------------------------------
  // An unlink that was cut short
  // ---------------------------------------------------------------------------
  //
  // Unlinking a wallet from a vault the backend no longer has takes three
  // stores: the wallet's rows, the recovery graph, and this device's copy of
  // the vault (data key, phrase, record). The rows come first and cannot be
  // undone, and either of the other two can fail or be cut off by the app
  // dying. Afterwards nothing would point at the vault any more: the rows
  // name no vault, so no check finds the copy that was left behind.
  //
  // So the unlink is written down before the rows are touched
  // ([beginUnlink]) and crossed out by the step that finishes it
  // ([forgetLocal]). What is still written down at the next check is
  // finished then.

  /// Write down that the wallet of [accountId] is being unlinked from
  /// [vaultId]. Throws when it cannot be kept — the caller then stops
  /// before unlinking anything, and the whole unlink can be asked for again.
  Future<void> beginUnlink(String vaultId, String accountId) => _editMissing(
    (record) => record.unlinking
      ..removeWhere((u) => u.vaultId == vaultId)
      ..add(PendingSocialVaultUnlink(vaultId: vaultId, accountId: accountId)),
    mustSave: true,
  );

  /// The unlinks that were begun and not seen through to [forgetLocal].
  Future<List<PendingSocialVaultUnlink>> pendingUnlinks() async =>
      List.unmodifiable((await _missing()).unlinking);

  /// Cross out the unlink written down for [vaultId] without finishing it:
  /// it never reached the wallet's rows, or the wallet is linked again.
  Future<void> dropPendingUnlink(String vaultId) => _editMissing(
    (record) => record.unlinking.removeWhere((u) => u.vaultId == vaultId),
  );

  /// Ask the backend about the retired vault [vaultId] again, with a status
  /// read signed by the data key set aside for it — at most once per
  /// [retiredCheckInterval] — and act on the answer:
  ///
  /// - **"not found" again**, and the unlink is at least [retiredEntriesAge]
  ///   old: the vault's platform entries are deleted, with the data key and
  ///   the record ([RetiredSocialVaultCheck.entriesDeleted]). Younger than
  ///   that, only the time of the check is kept.
  /// - **the vault is there** and this device's key opens it: the vault is
  ///   returned, opened, for the caller to link the wallet back
  ///   ([RetiredSocialVaultCheck.unlocked]). Nothing was ever deleted, so
  ///   nothing has to be put back.
  /// - **the vault is there under another key** (it was rotated elsewhere):
  ///   the key set aside is useless and is dropped with the record. The
  ///   entries stay; signing in links the wallet back.
  /// - **anything else** — no answer, a rate limit, a wrong clock, a 404
  ///   that is not the backend's own "no such vault", a record that is not
  ///   this vault's, no key to sign with: nothing changes. Entries are never
  ///   deleted on anything but a "not found".
  ///
  /// And "not found" is believed only from the backend the vault was known
  /// to live on when its wallet was unlinked. A record that names another
  /// backend is not asked about at all. One that names none is asked about,
  /// and a vault that is there is handed back as above — but its "not
  /// found" only moves the time of the check, however old the unlink is.
  ///
  /// Never throws.
  Future<RetiredSocialVaultCheck> checkRetired(String vaultId) async {
    try {
      return await _operations.run(vaultId, () => _checkRetired(vaultId));
    } catch (e) {
      AppLogger.info(_tag, 'retired vault not checked: ${e.runtimeType}');
      return const RetiredSocialVaultCheck.nothing();
    }
  }

  Future<RetiredSocialVaultCheck> _checkRetired(String vaultId) async {
    final retired = (await _missing()).retired.firstWhereOrNull(
      (r) => r.vaultId == vaultId,
    );
    if (retired == null) return const RetiredSocialVaultCheck.nothing();
    final origin = _originOfRecord(retired.apiOrigin);
    if (origin == _VaultOrigin.elsewhere) {
      return const RetiredSocialVaultCheck.nothing();
    }
    final now = _clock().toUtc();
    if (now.difference(retired.lastCheckedAt).abs() < retiredCheckInterval) {
      return const RetiredSocialVaultCheck.nothing();
    }
    final raw = await _storage.loadSocialVaultRetiredKey(vaultId);
    // Without the key no status read can be signed, so nothing can show
    // that the vault is still gone: its entries stay.
    if (raw == null || raw.isEmpty) {
      return const RetiredSocialVaultCheck.nothing();
    }
    final dataKey = SocialVaultCrypto.decodeBase64UrlNoPad(raw);
    Future<void> checked() =>
        _editRetired(vaultId, (r) => r.copyWith(lastCheckedAt: now));
    final api.SocialVault vault;
    try {
      vault = _recordOf(
        vaultId,
        await _api.status(
          vaultKey: await SocialVaultCrypto.vaultKeyPair(
            dataKey: dataKey,
            vaultId: vaultId,
          ),
          vaultId: vaultId,
          revision: 1,
        ),
      );
    } on SocialVaultApiException catch (e) {
      switch (e.error) {
        case SocialVaultApiError.notFound:
          // A clock that went backwards proves no age.
          final old =
              !now.isBefore(retired.unlinkedAt) &&
              now.difference(retired.unlinkedAt) >= retiredEntriesAge;
          if (!old || origin != _VaultOrigin.here) {
            await checked();
            return const RetiredSocialVaultCheck.nothing();
          }
          AppLogger.warn(_tag, 'a retired vault is still gone; entries freed');
          await forgetPlatformEntries(vaultId);
          await forgetRetired(vaultId);
          return const RetiredSocialVaultCheck.entriesDeleted();
        case SocialVaultApiError.signatureRejected:
          await forgetRetired(vaultId);
          return const RetiredSocialVaultCheck.nothing();
        default:
          return const RetiredSocialVaultCheck.nothing();
      }
    }
    try {
      final unlocked = await _open(vault, dataKey, '');
      // Asked and answered: if the caller cannot link the wallet back, the
      // next try is a day away like any other.
      await checked();
      return RetiredSocialVaultCheck.exists(unlocked);
    } on SocialVaultCryptoException {
      // There, but not under this key.
      await forgetRetired(vaultId);
      return const RetiredSocialVaultCheck.nothing();
    }
  }

  /// Whether this device's data key still signs for the vault as last seen.
  /// False when there is no key, or when the cached record carries another
  /// vault key (rotated elsewhere).
  ///
  /// It only compares, and deletes nothing: the cached record is this
  /// device's memory of the vault, not an answer from the backend, and the
  /// two can be read here in the middle of a write that is replacing both.
  /// A key that really is stale is dropped by the next status read or
  /// write, on the backend's own word ([_dropStaleDataKey]).
  Future<bool> hasUsableDataKey(String vaultId) async {
    final dataKey = await loadDataKey(vaultId);
    if (dataKey == null) return false;
    final vault = (await cached(vaultId))?.vault;
    if (vault == null) return true;
    final ours = await SocialVaultCrypto.vaultPublicKey(
      await SocialVaultCrypto.vaultKeyPair(dataKey: dataKey, vaultId: vaultId),
    );
    return ours == vault.vaultPublicKey;
  }

  Future<api.SocialVaultNewSlot> _platformSlot(
    String vaultId,
    Uint8List dataKey,
    PlatformSlotEntry entry,
  ) async {
    final wrapped = await SocialVaultCrypto.wrapDataKey(
      vaultId: vaultId,
      slotId: entry.slotId,
      kind: SocialVaultSlotKind.platform,
      slotSecret: entry.secret,
      dataKey: dataKey,
    );
    return api.SocialVaultNewSlot(
      slotId: entry.slotId,
      kind: api.SocialVaultSlotKind.platform,
      nonce: wrapped.nonceWire,
      wrappedKey: wrapped.ciphertextWire,
      // The label is written once and read on every device, for as long as
      // the slot lives. On Android it names the phone and claims nothing
      // about a backup: whether the entry is in Google's backup changes with
      // the phone's screen lock, and the Sign-in keys screen says which it is
      // now.
      label: _label(
        Platform.isIOS ? 'iCloud Keychain' : 'Android phone',
        await _deviceName(),
      ),
    );
  }

  Future<api.SocialVaultNewSlot> _passkeySlot({
    required String vaultId,
    required Uint8List dataKey,
    required String userName,
    required List<api.SocialVaultSlot> existing,
  }) async {
    final salt = SocialVaultCrypto.randomBytes(SocialVaultCrypto.keyLength);
    final registration = await _passkeys.register(
      rpId: _rpId,
      // One WebAuthn user per vault, so a platform files every passkey of
      // this wallet under one entry.
      userId: vaultId,
      userName: userName,
      salt: salt,
      excludeCredentialIds: [
        for (final s in existing)
          if (s.credentialId != null && s.rpId == _rpId)
            SocialVaultCrypto.canonicalCredentialId(s.credentialId!),
      ],
    );
    final slotId = SocialVaultCrypto.newSlotId();
    final wrapped = await SocialVaultCrypto.wrapDataKey(
      vaultId: vaultId,
      slotId: slotId,
      kind: SocialVaultSlotKind.passkeyPrf,
      slotSecret: registration.output,
      dataKey: dataKey,
    );
    return api.SocialVaultNewSlot(
      slotId: slotId,
      kind: api.SocialVaultSlotKind.passkeyPrf,
      nonce: wrapped.nonceWire,
      wrappedKey: wrapped.ciphertextWire,
      prfSalt: SocialVaultCrypto.base64UrlNoPad(salt),
      credentialId: SocialVaultCrypto.canonicalCredentialId(
        registration.credentialId,
      ),
      rpId: _rpId,
      label: _label('Passkey', await _deviceName()),
    );
  }

  static Uint8List _salt(api.SocialVaultSlot slot) =>
      SocialVaultCrypto.decodeBase64UrlNoPad(slot.prfSalt!);

  /// The label a new slot is given: its kind and the device's name, by the
  /// same rule as a name the user types ([displaySlotLabel]) — a device
  /// name is free text too — and cut to what the backend keeps, on a code
  /// point.
  static String _label(String kind, String device) {
    final name = displaySlotLabel(device);
    final label = name == null ? kind : '$kind · $name';
    final runes = label.runes;
    return runes.length <= maxSlotLabelLength
        ? label
        : String.fromCharCodes(runes.take(maxSlotLabelLength)).trimRight();
  }

  static Future<String> _defaultDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isIOS) return (await info.iosInfo).model;
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        return '${android.manufacturer} ${android.model}'.trim();
      }
    } catch (_) {}
    return '';
  }

  static Future<int?> _defaultAndroidSdkInt() async {
    if (!Platform.isAndroid) return null;
    try {
      return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    } catch (_) {
      return null;
    }
  }

  /// Whether this is an Android version that can neither back a platform
  /// entry up with end-to-end encryption nor use a passkey.
  Future<bool> _androidTooOld() async {
    final sdk = await _androidSdkInt();
    return sdk != null && sdk < _minAndroidSdk;
  }

  Future<void> _deletePlatformEntryQuietly(
    String vaultId,
    String slotId,
  ) async {
    try {
      await _platform.delete(vaultId, slotId);
    } catch (e) {
      AppLogger.warn(_tag, 'platform slot not deleted: ${e.runtimeType}');
    }
  }

  // ---------------------------------------------------------------------------
  // This device's copy
  // ---------------------------------------------------------------------------

  /// Keep what later writes and exports need: the data key, the recovery
  /// phrase, and a non-secret copy of the vault record.
  ///
  /// The record kept is the one that was opened, whatever revision this
  /// device had cached: it is the record the stored data key speaks for,
  /// and a sign-in is how a device catches up with a backend that went back
  /// to an older copy. It names this build's backend as where the vault
  /// lives, since a sign-in there just returned it.
  ///
  /// Takes its turn in the vault's queue, so that storing the key and
  /// settling an unconfirmed creation are one step to a sweep
  /// ([sweepAbandonedCreates]) or a status read.
  Future<void> persist(
    UnlockedSocialVault unlocked, {
    required String provider,
    String? emailHint,
  }) {
    final vaultId = unlocked.vault.vaultId;
    return _operations.run(vaultId, () async {
      await _storage.storeSocialVaultDataKey(
        vaultId,
        SocialVaultCrypto.base64UrlNoPad(unlocked.dataKey),
      );
      await _storage.storeSocialVaultMnemonic(
        vaultId,
        unlocked.payload.mnemonic,
      );
      // A wallet here uses the vault now, so its creation is settled — and
      // it was just opened, so it exists: an earlier "not found" for it
      // counts for nothing, a wallet unlinked on one is linked again, and an
      // unlink that was being finished no longer applies.
      await _settlePendingCreate(vaultId);
      await _clearNotFound(vaultId);
      await forgetRetired(vaultId);
      await dropPendingUnlink(vaultId);
      final vault = withDisplayLabels(unlocked.vault);
      await _editCache(
        vaultId,
        (previous) => CachedSocialVault(
          vault: vault,
          provider: provider,
          emailHint: emailHint,
          apiOrigin: _currentOrigin,
          seenSlotIds: _seenAfterObserving(previous, vault),
          acknowledgedDeletion: previous?.acknowledgedDeletion,
        ),
      );
    });
  }

  /// This device's data key for [vaultId], or null when it holds none.
  Future<Uint8List?> loadDataKey(String vaultId) async {
    final raw = await _storage.loadSocialVaultDataKey(vaultId);
    if (raw == null || raw.isEmpty) return null;
    return SocialVaultCrypto.decodeBase64UrlNoPad(raw);
  }

  Future<CachedSocialVault?> cached(String vaultId) async {
    final raw = await _storage.loadSocialVaultCache(vaultId);
    if (raw == null) return null;
    return CachedSocialVault.tryParse(raw);
  }

  /// Whether this device holds [vaultId]'s recovery phrase. It does after
  /// any sign-in that opened the vault here.
  Future<bool> hasMnemonic(String vaultId) async {
    final phrase = await _storage.loadSocialVaultMnemonic(vaultId);
    return phrase != null && phrase.isNotEmpty;
  }

  /// Keep [vaultId]'s recovery phrase under [accountId] as well, so the
  /// wallet can still be exported once it is unlinked from the vault — the
  /// phrase is then its only backup. A copy, repeatable; the vault's own
  /// items are dropped afterwards by [forgetLocal].
  Future<void> keepMnemonicForAccount(String vaultId, String accountId) async {
    final phrase = await _storage.loadSocialVaultMnemonic(vaultId);
    if (phrase == null || phrase.isEmpty) return;
    await _storage.storeSocialAccountMnemonic(accountId, phrase);
  }

  /// Drop this device's copy of [vaultId]: after its wallet is removed from
  /// the device, or after the wallet was unlinked from the vault. Platform
  /// entries are not touched here: for a vault that still exists, other
  /// devices may rely on them (see [forgetPlatformEntries]). Neither is a
  /// data key set aside by [retire].
  ///
  /// It is the last step of an unlink, and crosses that unlink out of the
  /// journal ([beginUnlink]) once everything else is gone. Repeatable.
  Future<void> forgetLocal(String vaultId) =>
      _operations.run(vaultId, () async {
        await _clearNotFound(vaultId);
        await _storage.deleteSocialVaultDataKey(vaultId);
        await _storage.deleteSocialVaultMnemonic(vaultId);
        await _records.run(
          vaultId,
          () => _storage.deleteSocialVaultCache(vaultId),
        );
        _lastStatusRead.remove(vaultId);
        await dropPendingUnlink(vaultId);
        changes.value++;
      });

  // ---------------------------------------------------------------------------
  // Sign-in keys this device has seen
  // ---------------------------------------------------------------------------
  //
  // The cached record carries the ids of the slots this device has seen
  // ([CachedSocialVault.seenSlotIds]). A slot in a later record that is not
  // among them was added somewhere else, and the user is told once. No list
  // (a device that never opened the vault, or one whose cached record was
  // lost) means there is nothing to compare against, never "all seen": the
  // first record such a device sees becomes the list, silently.

  /// The slots of the cached record this device has not seen before, oldest
  /// first. Empty when it has no list to compare against.
  Future<List<api.SocialVaultSlot>> unseenSlots(String vaultId) async {
    final record = await cached(vaultId);
    final seen = record?.seenSlotIds;
    if (record == null || seen == null) return const [];
    return [
      for (final slot in record.vault.slots)
        if (!seen.contains(slot.slotId)) slot,
    ];
  }

  /// The user has been told about the slots [slotIds]: they are seen from
  /// here on. Only those — a slot that arrived while the notice was up is
  /// still to be shown.
  Future<void> acknowledgeSlots(String vaultId, Iterable<String> slotIds) =>
      _editCache(
        vaultId,
        (record) => record?.copyWith(
          seenSlotIds: {...?record.seenSlotIds, ...slotIds}.toList(),
        ),
      );

  /// Whether the cached record carries a deletion request the user has not
  /// answered "it was me" to. Null when nothing is pending or it was
  /// acknowledged.
  Future<api.SocialVaultPendingDeletion?> unacknowledgedDeletion(
    String vaultId,
  ) async {
    final record = await cached(vaultId);
    final pending = record?.vault.pendingDeletion;
    if (pending == null) return null;
    return record!.acknowledgedDeletion == pending.requestedAt ? null : pending;
  }

  /// The user said the pending deletion requested at [requestedAt] was
  /// theirs. Remembered for that request only: a new request warns again.
  Future<void> acknowledgeDeletion(String vaultId, String requestedAt) =>
      _editCache(
        vaultId,
        (record) => record?.copyWith(acknowledgedDeletion: requestedAt),
      );

  /// What this device has seen once it has looked at [vault]: the list it
  /// had, or — with no list — every slot of [vault].
  static List<String> _seenAfterObserving(
    CachedSocialVault? previous,
    api.SocialVault vault,
  ) => previous?.seenSlotIds ?? [for (final s in vault.slots) s.slotId];

  /// Take [vault], as read from the backend (a status read, a conflict
  /// answer) and checked to be this vault's ([_recordOf]), into the cached
  /// record. Slots it lists that this device has not seen stay unseen.
  ///
  /// A record older than the cached one (a lower revision) never replaces
  /// it: answers can be acted on out of the order the backend gave them in,
  /// and an older record put back would list keys that are gone and name a
  /// vault key that was rotated away. Either way the answer shows the vault
  /// on this build's backend, which the record then names.
  Future<void> _observe(api.SocialVault vault) async {
    await _clearNotFound(vault.vaultId);
    await _editCache(vault.vaultId, (previous) {
      final kept = _newerOf(previous?.vault, vault);
      return CachedSocialVault(
        vault: kept,
        provider: previous?.provider,
        emailHint: previous?.emailHint,
        apiOrigin: _currentOrigin,
        seenSlotIds: _seenAfterObserving(previous, kept),
        acknowledgedDeletion: previous?.acknowledgedDeletion,
        staleKeyNotice: previous?.staleKeyNotice ?? false,
      );
    });
  }

  /// [answer], unless [cached] is a later revision of the vault.
  static api.SocialVault _newerOf(
    api.SocialVault? cached,
    api.SocialVault answer,
  ) => cached != null && cached.revision > answer.revision ? cached : answer;

  /// Take [vault], the answer to a write this device made, into the cached
  /// record. [ownSlotIds] — the slots that write added — are seen. Anything
  /// else new in [vault] came from another device and stays unseen.
  ///
  /// Like [_observe], it never puts an older record in place of a newer
  /// one; the slots this device added are seen all the same.
  Future<void> _updateCache(
    api.SocialVault vault, {
    Set<String> ownSlotIds = const {},
  }) async {
    await _clearNotFound(vault.vaultId);
    await _editCache(vault.vaultId, (previous) {
      final seen = previous?.seenSlotIds;
      return CachedSocialVault(
        vault: _newerOf(previous?.vault, vault),
        provider: previous?.provider,
        emailHint: previous?.emailHint,
        apiOrigin: _currentOrigin,
        // No list stays no list: the next record this device observes
        // becomes it.
        seenSlotIds: seen == null ? null : {...seen, ...ownSlotIds}.toList(),
        acknowledgedDeletion: previous?.acknowledgedDeletion,
        staleKeyNotice: previous?.staleKeyNotice ?? false,
      );
    });
  }

  /// Change the cached record of [vaultId]: [edit] is given the record as
  /// it is stored now and answers the one to store, or null to leave it.
  ///
  /// Every change to the record goes through here, one at a time
  /// ([_records]). Each is a read followed by a write, and two of them
  /// crossing would write one's reading back over the other's change: a
  /// status answer over the slots a write just marked as this device's own
  /// (the user is then told their own new passkey "was added"), or an
  /// acknowledged notice over a newer record.
  Future<void> _editCache(
    String vaultId,
    CachedSocialVault? Function(CachedSocialVault? previous) edit,
  ) => _records.run(vaultId, () async {
    final next = edit(await cached(vaultId));
    if (next == null) return;
    try {
      await _storage.storeSocialVaultCache(vaultId, next.toJsonString());
      changes.value++;
    } catch (e) {
      AppLogger.warn(_tag, 'vault cache not saved: ${e.runtimeType}');
    }
  });
}

/// Where a vault stands to the backend this build talks to. See
/// `SocialVaultService._originOfRecord`.
enum _VaultOrigin {
  /// This backend showed the vault exists: its "not found" may be believed.
  here,

  /// Nothing recorded yet (a record written before the origin was kept). The
  /// vault may be asked about; only an answer that it exists is acted on.
  unproven,

  /// Another backend holds the vault, or this build names no backend. It is
  /// not asked about, and no "not found" is believed.
  elsewhere,
}

/// Runs the actions given for one key strictly one after another, in the
/// order they were asked for. An action that throws does not hold up the
/// ones behind it. Not re-entrant: an action must not wait on another for
/// the same key.
class _Serial {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key];
    final done = Completer<void>();
    final tail = done.future;
    _tails[key] = tail;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      if (identical(_tails[key], tail)) unawaited(_tails.remove(key));
      done.complete();
    }
  }
}

/// A sign-in key label that cannot be stored: after cleaning it is longer
/// than `SocialVaultService.maxSlotLabelLength` code points. Thrown by
/// `SocialVaultService.normalizeSlotLabel` and so by `renameSlot`, before
/// anything is sent.
class SocialVaultLabelException implements Exception {
  const SocialVaultLabelException(this.length);

  /// The cleaned label's length, in code points.
  final int length;

  /// The most a label may have, in code points.
  int get maxLength => SocialVaultService.maxSlotLabelLength;

  @override
  String toString() => 'SocialVaultLabelException($length > $maxLength)';
}

/// An unlink of a wallet from its vault that was begun and not yet seen
/// through. See `SocialVaultService.beginUnlink`. Not secret.
class PendingSocialVaultUnlink {
  const PendingSocialVaultUnlink({
    required this.vaultId,
    required this.accountId,
  });

  final String vaultId;

  /// The account whose wallet is being unlinked.
  final String accountId;

  static PendingSocialVaultUnlink? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final vaultId = raw['vaultId'];
    final accountId = raw['accountId'];
    if (vaultId is! String || accountId is! String) return null;
    return PendingSocialVaultUnlink(vaultId: vaultId, accountId: accountId);
  }

  Map<String, Object?> toJson() => {'vaultId': vaultId, 'accountId': accountId};
}

/// What a status read of a vault found. See [SocialVaultService.checkStatus].
enum SocialVaultStatus {
  /// Not read: this device holds no data key for the vault, it was read
  /// too recently, or its record names another backend than the one this
  /// build talks to.
  skipped,

  /// The vault exists under the key this device holds; the cached record is
  /// the current one.
  current,

  /// The backend the vault lives on answered "not found" in its own words,
  /// and it is the first such answer or the first one is less than a day
  /// old. Nothing is concluded from it and nothing changes.
  unconfirmedGone,

  /// The backend answered "not found" again, at least a day after the first
  /// time. The caller unlinks the wallet and keeps its platform entries.
  gone,

  /// The vault is under another vault key; this device's data key was
  /// dropped.
  staleKey,

  /// No answer, or one that says nothing about the vault: offline, a wrong
  /// clock, a rate limit, a 404 that is not the backend's own "no such
  /// vault" (or is, from a backend the vault was never seen on), a record
  /// that is not this vault's or is older than the cached one. Nothing
  /// changed.
  failed,
}

/// How a signed delete of a vault ended. See [SocialVaultService.deleteVault].
enum SocialVaultDeletion {
  /// The backend accepted the delete; the vault's platform entries are gone
  /// too.
  deleted,

  /// The backend answered that there is no such vault. Nothing was deleted.
  notFound,

  /// This device holds no data key that signs for the vault. Nothing was
  /// sent.
  noKey,
}

/// A vault a wallet on this device was unlinked from because the backend
/// said it does not exist. Its platform entries are kept, and so is its data
/// key (aside), until [SocialVaultService.checkRetired] settles it. Not
/// secret.
class RetiredSocialVault {
  const RetiredSocialVault({
    required this.vaultId,
    required this.accountId,
    required this.provider,
    required this.unlinkedAt,
    required this.lastCheckedAt,
    this.identityId,
    this.emailHint,
    this.apiOrigin,
    this.announced = false,
  });

  final String vaultId;

  /// The account whose wallet was unlinked.
  final String accountId;

  /// `google` or `apple`.
  final String provider;

  /// The sign-in identity the link recorded, to put back on a re-link.
  final String? identityId;
  final String? emailHint;

  /// The origin of the backend the vault was known to live on when its wallet
  /// was unlinked, or null when none was recorded. Only that backend's "not
  /// found" frees the vault's entries.
  final String? apiOrigin;

  final DateTime unlinkedAt;

  /// When the backend was last asked about the vault (the unlink, at first).
  final DateTime lastCheckedAt;

  /// Whether the user has been told the backup is no longer stored.
  final bool announced;

  RetiredSocialVault copyWith({DateTime? lastCheckedAt, bool? announced}) =>
      RetiredSocialVault(
        vaultId: vaultId,
        accountId: accountId,
        provider: provider,
        identityId: identityId,
        emailHint: emailHint,
        apiOrigin: apiOrigin,
        unlinkedAt: unlinkedAt,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
        announced: announced ?? this.announced,
      );

  static RetiredSocialVault? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final vaultId = raw['vaultId'];
    final accountId = raw['accountId'];
    final provider = raw['provider'];
    final unlinkedAt = _MissingVaults.time(raw['unlinkedAt']);
    if (vaultId is! String ||
        accountId is! String ||
        provider is! String ||
        unlinkedAt == null) {
      return null;
    }
    final identityId = raw['identityId'];
    final emailHint = raw['emailHint'];
    final apiOrigin = raw['apiOrigin'];
    return RetiredSocialVault(
      vaultId: vaultId,
      accountId: accountId,
      provider: provider,
      identityId: identityId is String ? identityId : null,
      emailHint: emailHint is String ? emailHint : null,
      apiOrigin: apiOrigin is String && apiOrigin.isNotEmpty ? apiOrigin : null,
      unlinkedAt: unlinkedAt,
      lastCheckedAt: _MissingVaults.time(raw['lastCheckedAt']) ?? unlinkedAt,
      announced: raw['announced'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'vaultId': vaultId,
    'accountId': accountId,
    'provider': provider,
    'identityId': identityId,
    'emailHint': emailHint,
    'apiOrigin': apiOrigin,
    'unlinkedAt': unlinkedAt.millisecondsSinceEpoch ~/ 1000,
    'lastCheckedAt': lastCheckedAt.millisecondsSinceEpoch ~/ 1000,
    'announced': announced,
  };
}

/// What [SocialVaultService.checkRetired] found.
///
/// Hand-written with no [toString] of its own content: [unlocked] carries
/// secrets (and redacts itself).
class RetiredSocialVaultCheck {
  /// Not asked, no usable answer, or still "not found" inside the keeping
  /// period. Nothing changed that a caller has to act on.
  const RetiredSocialVaultCheck.nothing()
    : unlocked = null,
      entriesDeleted = false;

  /// "Not found" again after the keeping period: the vault's platform
  /// entries were deleted and it is no longer kept track of.
  const RetiredSocialVaultCheck.entriesDeleted()
    : unlocked = null,
      entriesDeleted = true;

  /// The vault exists and the data key set aside opens it.
  const RetiredSocialVaultCheck.exists(UnlockedSocialVault this.unlocked)
    : entriesDeleted = false;

  final UnlockedSocialVault? unlocked;
  final bool entriesDeleted;
}

/// What this device has written down about vaults the backend answered "not
/// found" for, and about unlinks from such vaults that are under way.
class _MissingVaults {
  _MissingVaults();

  factory _MissingVaults.fromJson(Object? raw) {
    final record = _MissingVaults();
    if (raw is! Map) return record;
    final first = raw['firstNotFound'];
    if (first is Map) {
      for (final MapEntry(:key, :value) in first.entries) {
        final at = time(value);
        if (key is String && at != null) record.firstNotFound[key] = at;
      }
    }
    final retired = raw['retired'];
    if (retired is List) {
      record.retired.addAll([
        for (final item in retired) ?RetiredSocialVault.tryParse(item),
      ]);
    }
    final unlinking = raw['unlinking'];
    if (unlinking is List) {
      record.unlinking.addAll([
        for (final item in unlinking) ?PendingSocialVaultUnlink.tryParse(item),
      ]);
    }
    return record;
  }

  /// When a status read first answered "not found" for a linked vault, by
  /// vault id.
  final Map<String, DateTime> firstNotFound = <String, DateTime>{};

  final List<RetiredSocialVault> retired = <RetiredSocialVault>[];

  /// Unlinks that were begun and not yet seen through.
  final List<PendingSocialVaultUnlink> unlinking = <PendingSocialVaultUnlink>[];

  static DateTime? time(Object? seconds) => seconds is int && seconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      : null;

  Map<String, Object?> toJson() => {
    'firstNotFound': {
      for (final MapEntry(:key, :value) in firstNotFound.entries)
        key: value.millisecondsSinceEpoch ~/ 1000,
    },
    'retired': [for (final r in retired) r.toJson()],
    'unlinking': [for (final u in unlinking) u.toJson()],
  };
}

/// A vault creation this device started and has not seen confirmed.
class _PendingCreate {
  const _PendingCreate({
    required this.vaultId,
    required this.slotId,
    required this.createdAt,
    this.apiOrigin,
  });

  final String vaultId;
  final String slotId;
  final DateTime createdAt;

  /// The origin of the backend the creation was sent to, or null for a record
  /// written before it was kept.
  final String? apiOrigin;

  static _PendingCreate? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final vaultId = raw['vaultId'];
    final slotId = raw['slotId'];
    final createdAt = raw['createdAt'];
    if (vaultId is! String || slotId is! String || createdAt is! int) {
      return null;
    }
    final apiOrigin = raw['apiOrigin'];
    return _PendingCreate(
      vaultId: vaultId,
      slotId: slotId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAt * 1000,
        isUtc: true,
      ),
      apiOrigin: apiOrigin is String && apiOrigin.isNotEmpty ? apiOrigin : null,
    );
  }

  Map<String, Object?> toJson() => {
    'vaultId': vaultId,
    'slotId': slotId,
    'createdAt': createdAt.millisecondsSinceEpoch ~/ 1000,
    'apiOrigin': apiOrigin,
  };
}

/// An open vault: its record, its data key and its payload.
///
/// Hand-written with a redacted [toString]: [dataKey] and [payload] are
/// secrets.
class UnlockedSocialVault {
  const UnlockedSocialVault({
    required this.vault,
    required this.dataKey,
    required this.payload,
    required this.openedWithSlotId,
  });

  final api.SocialVault vault;
  final Uint8List dataKey;
  final SocialVaultPayload payload;
  final String openedWithSlotId;

  UnlockedSocialVault withVault(api.SocialVault updated) => UnlockedSocialVault(
    vault: updated,
    dataKey: dataKey,
    payload: payload,
    openedWithSlotId: openedWithSlotId,
  );

  @override
  String toString() =>
      'UnlockedSocialVault(${vault.vaultId}, revision ${vault.revision}, '
      '<redacted>)';
}

/// The last vault record this device saw, with what this device remembers
/// about it. Not secret.
class CachedSocialVault {
  const CachedSocialVault({
    required this.vault,
    required this.provider,
    required this.emailHint,
    this.apiOrigin,
    this.seenSlotIds,
    this.acknowledgedDeletion,
    this.staleKeyNotice = false,
  });

  final api.SocialVault vault;
  final String? provider;
  final String? emailHint;

  /// The origin (`scheme://host:port`) of the backend that last showed this
  /// vault exists — the one it lives on — or null for a record written
  /// before it was kept. "Not found" is believed only from that backend: see
  /// `SocialVaultService.checkStatus`.
  final String? apiOrigin;

  /// This device's data key was found stale by a status read, and the user
  /// has not been told yet. See `SocialVaultService.staleKeyNoticeDue`.
  final bool staleKeyNotice;

  /// The ids of the slots this device has seen, or null when it has no such
  /// list yet. Null is "nothing to compare against", never "all seen".
  final List<String>? seenSlotIds;

  /// The `requestedAt` of the pending deletion request the user answered
  /// "it was me" to, if any.
  final String? acknowledgedDeletion;

  CachedSocialVault copyWith({
    String? apiOrigin,
    List<String>? seenSlotIds,
    String? acknowledgedDeletion,
    bool? staleKeyNotice,
  }) => CachedSocialVault(
    vault: vault,
    provider: provider,
    emailHint: emailHint,
    apiOrigin: apiOrigin ?? this.apiOrigin,
    seenSlotIds: seenSlotIds ?? this.seenSlotIds,
    acknowledgedDeletion: acknowledgedDeletion ?? this.acknowledgedDeletion,
    staleKeyNotice: staleKeyNotice ?? this.staleKeyNotice,
  );

  static CachedSocialVault? tryParse(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final seen = map['seenSlotIds'];
      final apiOrigin = map['apiOrigin'];
      return CachedSocialVault(
        // Cleaned on the way out as on the way in: a record kept by an
        // earlier build may carry a label this one would not draw.
        vault: SocialVaultService.withDisplayLabels(
          api.SocialVault.fromJson(map['vault'] as Map<String, dynamic>),
        ),
        provider: map['provider'] as String?,
        emailHint: map['emailHint'] as String?,
        apiOrigin: apiOrigin is String && apiOrigin.isNotEmpty
            ? apiOrigin
            : null,
        seenSlotIds: seen is List ? seen.whereType<String>().toList() : null,
        acknowledgedDeletion: map['acknowledgedDeletion'] as String?,
        staleKeyNotice: map['staleKeyNotice'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode({
    'vault': vault.toJson(),
    'provider': provider,
    'emailHint': emailHint,
    'apiOrigin': apiOrigin,
    'seenSlotIds': seenSlotIds,
    'acknowledgedDeletion': acknowledgedDeletion,
    'staleKeyNotice': staleKeyNotice,
  });
}

/// No slot of the vault can be used on this device — or, when [creating], no
/// slot can be made here.
class SocialVaultUnlockException implements Exception {
  const SocialVaultUnlockException({
    required this.hasPasskeySlots,
    required this.passkeysSupportedHere,
    this.creating = false,
    this.platformStoreFull = false,
    this.platformTooOld = false,
  });

  /// This Android version (8 or 8.1) has neither an end-to-end encrypted
  /// phone backup nor passkeys, so a wallet made here could be opened with
  /// nothing. A screen lock would not change that.
  final bool platformTooOld;

  /// The platform store refused a new entry because it is full (Block Store
  /// keeps at most 16 per app), so no platform slot could be made.
  final bool platformStoreFull;

  /// The vault has passkey slots, so another device's passkey would open it.
  final bool hasPasskeySlots;

  /// This device can use passkeys (iOS 18+, Android 9+, configured).
  final bool passkeysSupportedHere;

  final bool creating;

  @override
  String toString() =>
      'SocialVaultUnlockException(passkeySlots: $hasPasskeySlots, '
      'passkeysHere: $passkeysSupportedHere, creating: $creating)';
}

/// What a removal by rotation keeps and drops. See
/// [SocialVaultService.planRemoval].
class SocialVaultRemovalPlan {
  const SocialVaultRemovalPlan({
    required this.removing,
    required this.newPlatformSlot,
    required this.passkeysToConfirm,
    required this.dropped,
  });

  /// The key the user chose to remove.
  final api.SocialVaultSlot removing;

  /// Whether this device makes a new platform slot of its own.
  final bool newPlatformSlot;

  /// Passkeys kept if the user confirms each one on this device now.
  final List<api.SocialVaultSlot> passkeysToConfirm;

  /// Keys dropped whatever happens, [removing] included.
  final List<api.SocialVaultSlot> dropped;
}

/// This device's data key no longer signs for [vaultId] (it was rotated), so
/// the write was refused and the key has been dropped — or this device holds
/// no data key for it at all. Signing in again reopens the vault through a
/// slot and picks up the current key.
class SocialVaultStaleKeyException implements Exception {
  const SocialVaultStaleKeyException(this.vaultId);

  final String vaultId;

  @override
  String toString() => 'SocialVaultStaleKeyException';
}

/// This device does not hold the recovery phrase of a vault wallet whose
/// backup it was asked to delete. Deleting the backup would leave the wallet
/// with no backup at all, so nothing was deleted; signing in again puts the
/// phrase back on the device.
class SocialVaultPhraseUnavailableException implements Exception {
  const SocialVaultPhraseUnavailableException();

  @override
  String toString() => 'SocialVaultPhraseUnavailableException';
}

/// A completed rotation: the vault after it, and the passkeys the plan
/// meant to keep that were not confirmed on this device (and are gone).
class SocialVaultRotation {
  const SocialVaultRotation({
    required this.vault,
    required this.unconfirmedPasskeys,
  });

  final api.SocialVault vault;
  final List<api.SocialVaultSlot> unconfirmedPasskeys;
}
