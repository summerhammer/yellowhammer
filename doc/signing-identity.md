# Signing identity and notarization credential

Roadmap P16.1. Yellowhammer ships as a Developer ID signed, notarized `.app` distributed
directly (spec: `docs/tech/stack.md` → Distribution). A release needs two credentials: the
**Developer ID Application** certificate (with its private key) and a **notarization
credential** (an App Store Connect API key). This page says where they live, who owns them,
and how to renew them. It never holds a secret.

## Ownership and expiry

Fill this table when the credentials are provisioned, and update it on every renewal.

| Credential | Apple team (ID) | Owner | Created | Expires | Renewal reminder |
|---|---|---|---|---|---|
| Developer ID Application certificate | _tbd_ | _tbd_ (Account Holder) | _tbd_ | _tbd_ (5 years) | 60 days before expiry |
| App Store Connect API key (notarization) | _tbd_ | _tbd_ (Admin) | _tbd_ | does not expire; revoke on owner change | yearly review |

- Only the Apple Developer **Account Holder** can create a Developer ID Application
  certificate. The team is limited to a small number of them, so renew rather than create.
- A certificate's expiry does not break already-shipped builds: they carry a secure
  timestamp. It does stop new releases, which is why `release-signing.yml` runs monthly.

## Where the credentials live

### CI (GitHub Actions secrets on `summerhammer/yellowhammer`)

| Secret | Content |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i developer-id.p12` — the certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | the password set when exporting that `.p12` |
| `NOTARY_API_KEY_BASE64` | `base64 -i AuthKey_<KEYID>.p8` |
| `NOTARY_API_KEY_ID` | the API key's Key ID |
| `NOTARY_API_ISSUER_ID` | the team's Issuer ID (App Store Connect → Users and Access → Integrations) |

Set them with `gh secret set <NAME> < file` (never paste into a shell history).
`scripts/release/setup-signing.sh` imports them into a temporary keychain, then signs a probe
binary with hardened runtime and a secure timestamp, and runs `notarytool history` to prove the
API key authenticates. `.github/workflows/release-signing.yml` runs it on demand and monthly.
A release job runs the same script before it builds.

### The release machine (login keychain)

1. Import the `.p12` into the login keychain (double-click, or
   `security import developer-id.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`).
2. Store the notarization credential as a keychain profile:

   ```sh
   xcrun notarytool store-credentials yellowhammer-notary \
       --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_ID>
   ```

3. Check both without manual input:

   ```sh
   DEVELOPER_TEAM_ID=<TEAMID> scripts/release/setup-signing.sh --verify-only
   ```

Set `DEVELOPER_TEAM_ID` whenever the keychain holds Developer ID identities of more than one
team; without it the script takes the first one.

## Renewal

1. **Certificate** (60 days before expiry): the Account Holder creates a new Developer ID
   Application certificate in the Apple Developer portal from a fresh CSR, exports it with its
   key as `.p12`, updates the two `DEVELOPER_ID_P12_*` secrets and the release machine's
   keychain, runs `release-signing.yml`, and updates the table above. Keep the old certificate
   until it expires; do not revoke it (revoking invalidates shipped builds).
2. **API key** (on owner change or suspected leak): create a new key in App Store Connect,
   update the three `NOTARY_API_*` secrets and re-run `store-credentials`, run
   `release-signing.yml`, then revoke the old key.
3. **Sparkle EdDSA key** is a separate credential and belongs to P16.5, not here.
