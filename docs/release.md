# Release runbook

How a tkzmux build gets from this repo onto someone else's Mac: version stamping (M6.1),
hardened runtime + notarization (M6.2), and `make dist` (M6.3).

> **Status:** the signed path is verified end to end. v0.1.0 was cut with `make dist` from the
> development Mac on 2026-09-09 — Developer ID identity, hardened runtime, `--timestamp`,
> notarization, stapling and `spctl` all exercised — and installs through the Homebrew cask as
> *accepted, source=Notarized Developer ID*. The ad-hoc path (`make app` with the default
> `SIGN_IDENTITY=-`) is unchanged and still the default for local builds.

---

## 1. One-time prerequisites (manual, all outside this repo)

None of these can be scripted; do them once, in order.

1. **Enrol in the Apple Developer Program** (99 USD/yr). A free Apple ID cannot issue a
   Developer ID certificate and cannot notarize.
2. **Create a "Developer ID Application" certificate** — Xcode › Settings › Accounts › Manage
   Certificates › + › Developer ID Application, or via developer.apple.com › Certificates.
   Verify the identity and its private key landed in the login keychain:

   ```sh
   security find-identity -v -p codesigning
   # 1) ABCD…  "Developer ID Application: Your Name (TEAMID)"
   #    1 valid identities found
   ```

   The quoted string is what goes in `SIGN_IDENTITY`. `0 valid identities found` means the
   private key is missing (a certificate downloaded on another Mac is useless without it —
   export a `.p12` from the Mac that generated the CSR).
3. **Create an App Store Connect API key** (App Store Connect › Users and Access › Integrations
   › App Store Connect API › Team Keys, role *Developer*): download the `AuthKey_<KEYID>.p8`
   **once**, and note the Key ID and the Issuer UUID. CI (§8) needs this key. An API key is
   preferred over an app-specific password: it is scoped to App Store Connect and does not die
   with the Apple ID password.
4. **Store the notary credentials in the keychain** under the profile name the Makefile expects.
   Keep the command out of `~/.zsh_history`: `setopt HIST_IGNORE_SPACE` (off in vanilla zsh),
   then type a leading space. The app-specific-password form otherwise leaves a plaintext
   password there.

   ```sh
   setopt HIST_IGNORE_SPACE
    xcrun notarytool store-credentials tkzmux-notary \
     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer 00000000-0000-0000-0000-000000000000
   ```

   The Apple-ID form (`--apple-id … --team-id … --password <app-specific password>`) also works
   for a laptop profile and is what the development Mac currently uses; `make dist` does not
   care which. Override the name with `NOTARY_PROFILE=…` if you prefer another.

**Entitlements: none, expected.** tkzmux does not JIT, does not allocate unsigned executable
memory, does not load third-party plug-ins, and does not disable library validation —
libghostty-vt is a *static* archive linked into the executable, not a dylib. Metal, `fork`/`exec`
of a login shell through `TkzPtyShim`, and pty I/O all work under the hardened runtime without
an entitlement. So there is deliberately **no `.entitlements` file**; do not add one
speculatively. If notarization or a first launch ever fails with a hardened-runtime rejection,
add the single narrowest entitlement the log names and record the reason here.

---

## 2. Version stamping

`scripts/make-app.sh` derives the version from `git describe --tags --match 'v*' --dirty` and
writes it into the **copied** `Contents/Info.plist` (the committed `Resources/Info.plist` keeps
its placeholders, so building never dirties the tree).

| `git describe` output     | `CFBundleShortVersionString` |
|---------------------------|------------------------------|
| *(empty — no v\* tag)*    | `0.0.0-dev+<sha>`            |
| *(empty, dirty tree)*     | `0.0.0-dev+<sha>.dirty`      |
| `v1.2.3`                  | `1.2.3`                      |
| `v1.2.3-dirty`            | `1.2.3-dev.0+<sha>.dirty`    |
| `v1.2.3-4-gabc1234`       | `1.2.3-dev.4+abc1234`        |
| `v1.2.3-4-gabc1234-dirty` | `1.2.3-dev.4+abc1234.dirty`  |
| `v1.0.0-rc1-2-gdeadbee`   | `1.0.0-rc1-dev.2+deadbee`    |

Parsed right-to-left (strip `-dirty`, then `-<N>-g<hex>`, then the leading `v`) so a prerelease
tag's own dashes survive. Notes for anything that parses these strings back:

- The discriminator for "this is a release" is **`-dev.` is absent**, not "there is no `-`":
  `v1.0.0-rc1` → `1.0.0-rc1` is a release, `1.0.0-rc1-dev.2+deadbee` is not. Everything with
  `-dev.` is a semver prerelease and sorts *below* the tag it was built from.
- `<sha>` is **not** fixed at 7 characters. Both `git describe` and `git rev-parse --short` use
  `core.abbrev=auto`, which grows with the repository, so match `[0-9a-f]{4,40}`.
- Dirty *on* an exact tag uses `N=0` and `git rev-parse --short HEAD` for the sha, because
  `git describe` emits no sha in that case: `1.2.3-dev.0+<sha>.dirty`.
- "Dirty" here means modified **tracked** files — untracked files are ignored, exactly as
  `git describe --dirty` does it. (`make dist` uses a stricter rule; see below.)
- `VERSION=…` is passed through **verbatim, unvalidated**, so a parser either tolerates
  arbitrary strings or documents its contract as "derived strings only".

Also stamped:

- `CFBundleVersion` = `git rev-list --count HEAD` — monotonic, no state outside the repo.
- `TkzGhosttyCommit` = `vendor/ghostty-vt/COMMIT`, so a bug report identifies the VT library.

`VERSION=1.2.3 make app` overrides the derivation verbatim.

---

## 3. Signing

`SIGN_IDENTITY` is the only switch:

```sh
make app                                                  # ad-hoc, local use only
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" make app
```

A real identity additionally turns on `--options runtime --timestamp`. Two things that are easy
to get wrong and are handled in `scripts/make-app.sh`:

- **Signing is inside-out, never `--deep`.** `Contents/MacOS/tkzmux-hook` is a second Mach-O
  inside the bundle. `codesign --verify --deep --strict` passes on an *unsigned* helper there
  because it is sealed as an ordinary resource — but the notary service inspects every Mach-O it
  finds and rejects an unsigned one. The helper is signed first with its own identifier
  (`se.tkz.tkzmux.hook`), then the bundle. `make app` verifies the helper's own signature
  separately for exactly this reason.
- **`--timestamp` is only added for a real identity.** It errors out against an ad-hoc
  signature. It also needs the network (Apple's timestamp server), so a signed build cannot be
  made offline; an ad-hoc build can.

---

## 4. Cutting a release

```sh
git tag -a v0.1.0 -m 'tkzmux 0.1.0'
git push origin v0.1.0
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" make dist
```

Pushing that tag also starts `.github/workflows/release.yml`, which runs this same `make dist`
on a runner — and the two would race for `gh release create`. **CI owns a pushed `v*` tag.** To
cut a release by hand instead, put `[skip release]` (or `[skip-release]`, both spellings are
accepted) in the tag message — or, for a lightweight tag, in the tagged commit's message:

```sh
git tag -a v0.1.2 -m 'tkzmux 0.1.2 [skip release]'
```

The gate job reads it over the API and stands down, leaving the tag to the local `make dist`
above. Everything else is identical — same script, same asset name. A *lightweight* tag
(`git tag v0.1.2`, no `-a`/`-m`) has nowhere to carry a message of its own, which is why the gate
falls back to the commit; v0.1.0 was lightweight, so that fallback is the likely path rather than
an edge case. If a CI release fails partway instead, delete the partial release (§7) and run
`make dist` locally for the same tag.

`make dist` (`scripts/make-dist.sh`) refuses to build anything until all of these hold, and
reports *every* violation at once rather than one per round trip:

- `SIGN_IDENTITY` is not `-`;
- `git status --porcelain` is empty — **stricter than the version stamp's notion of dirty**, and
  deliberately so: `swift build` compiles every `Sources/**/*.swift` on disk, so an *untracked*
  file would be inside the notarized binary yet absent from the tag. (The version stamp keeps
  git's own definition, tracked-only, because that is what the string means.)
- HEAD carries a `v*` tag;
- that tag exists on `origin` — the one guard that needs the network. Without it
  `gh release create` silently invents the tag at the default branch head. `--verify-tag` on the
  `gh` call is the second interlock at the point of use.

Then it: builds signed (`make app`) → notarizes and staples (`make notarize`) → re-zips the
**stapled** bundle → writes the sha256 → creates the GitHub release.

```
build/dist/tkzmux-<version>-arm64.zip
build/dist/tkzmux-<version>-arm64.zip.sha256
build/dist/notes.md
```

The asset URL is a **hard contract** with the Homebrew cask — renaming the zip breaks every
cask already published:

```
https://github.com/tkz0/tkzmux/releases/download/v<version>/tkzmux-<version>-arm64.zip
```

The version in that name is read back out of the built app's `Info.plist`, not derived a second
time, so the file name and the app's own version can never disagree.

Knobs:

| Variable | Effect |
|---|---|
| `SIGN_IDENTITY` | required; the Developer ID string from `security find-identity` |
| `NOTARY_PROFILE` | `notarytool` keychain profile (default `tkzmux-notary`) |
| `DIST_DRAFT=1` | create the GitHub release as a draft |
| `TAP_DIR` | if set *and* `scripts/bump-cask.sh` exists, bump the cask after the release |

Release notes come from `git log <prev-tag>..HEAD --oneline`; on the very first release there is
no previous tag (`git describe --tags --abbrev=0 HEAD^` fails, and on a root commit there is no
`HEAD^` at all), so the range falls back to plain `HEAD` — root commit included.

`make notarize` can also be run on its own against an already-built `build/tkzmux.app`. It fails
loudly, with the command to run next, when `SIGN_IDENTITY` is `-`, when the app has not been
built, or when the submission comes back anything other than `status: Accepted` (it prints the
`xcrun notarytool log <id>` invocation that explains why).

---

## 5. Verify

```sh
spctl -a -vv -t exec build/tkzmux.app      # → accepted, source=Notarized Developer ID
xcrun stapler validate build/tkzmux.app    # → The validate action worked!
codesign -dv --verbose=4 build/tkzmux.app  # → Signature=..., Timestamp=..., flags=...(runtime)
codesign --verify --strict build/tkzmux.app/Contents/MacOS/tkzmux-hook
shasum -a 256 -c build/dist/*.sha256
```

The strongest check is the one no script can do: download the published zip on a Mac that has
never seen this build, unzip, and double-click. Gatekeeper only shows its real verdict on a
quarantined copy.

---

## 6. Bump the Homebrew cask

The cask lives in a **separate** repository, `tkz0/homebrew-tap`, as `Casks/tkzmux.rb`. Only two
stanzas ever change per release — `version` and `sha256` — because the `url` is built from
`#{version}` against the asset-name contract in §4.

`make dist` prints the version and sha256, and calls `scripts/bump-cask.sh <version> <sha256>`
automatically when `TAP_DIR` points at a tap checkout. Otherwise run it by hand with the two
values from the `make dist` summary:

```sh
TAP_DIR=~/dev/homebrew-tap scripts/bump-cask.sh 0.1.0 <sha256>
```

`TAP_DIR` must be an **existing clone with a push remote** — the script never clones and never
creates the remote. It rewrites the two stanzas, commits `tkzmux <version>` under a generic
identity (git on a runner has none configured), and pushes. Two behaviours worth knowing:

- **Re-running is a no-op, not an error.** `make dist` and the release workflow can both reach the
  bump for one tag; a bump that changes nothing exits 0 with *"tap already at `<version>`"*.
- **A `-dev.` version is rejected.** The version validator refuses build metadata (`+<sha>`), so
  the `1.2.3-dev.4+abc1234` form of §2 can never be published to the tap by accident.
  `BUMP_PUSH=0` commits without pushing; `BUMP_COMMIT=0` only rewrites the file.

**`depends_on macos: :tahoe` is the bare symbol on purpose — do not "fix" it back to
`">= :tahoe"`.** `brew style` rejects the string form (`Homebrew/OSDependsOn`), and the two mean
the same thing: `cask/dsl/depends_on.rb` parses a bare symbol with `comparator: ">="`, i.e.
macOS 26 or newer.

### Verifying the cask

```sh
brew style Casks/tkzmux.rb                         # must be clean before pushing a bump
brew trust --cask tkz0/tap/tkzmux                  # see below — once per machine
brew install --cask tkz0/tap/tkzmux
brew audit --cask --strict --online tkz0/tap/tkzmux
```

**Homebrew 6 will not load a cask from an untrusted third-party tap.** Without `brew trust`, both
`brew tap` and `brew install` refuse:

```
Refusing to load cask tkz0/tap/tkzmux from untrusted tap tkz0/tap.
Run `brew trust --cask tkz0/tap/tkzmux` or `brew trust tkz0/tap` to trust it.
Error: Invalid cask (macOS 12 on intel): …/Casks/tkzmux.rb
Error: Cannot tap tkz0/tap: invalid syntax in tap!
```

That last line reads like a broken cask and is not one — it is the aggregate of the refusals, and
`brew style` on the same file is clean. The trust list lives in `~/.homebrew/trust.json` (or
`$XDG_CONFIG_HOME/homebrew/trust.json`).

Two consequences: the tap's own README leads with the trust step, and **the release notes
`scripts/make-dist.sh` generates currently print `brew install --cask tkz0/tap/tkzmux` without
it** — anyone following them verbatim on a clean machine hits the refusal. Worth adding to the
notes template.

`brew audit --strict --online` fetches the `url` and checks the sha, so it can only be run
**after** the release assets are published — it is a post-bump check, not a pre-flight one. It
also needs the tap installed: `brew audit` no longer accepts a file path — it answers
*"Calling `brew audit [path ...]` is disabled!"* — only a `tap/cask` name.

---

## 7. Rollback

A published release cannot be un-downloaded, but it can be withdrawn:

```sh
gh release delete v0.1.0 --repo tkz0/tkzmux --yes   # removes the release + its assets
git push origin :refs/tags/v0.1.0                    # remove the remote tag
git tag -d v0.1.0                                    # and the local one
```

Then revert the cask bump in the tap. Prefer shipping `v0.1.1` over reusing a tag: anyone who
already downloaded `v0.1.0` has a binary whose sha no longer matches the cask.

Notarization itself cannot be revoked from here. If a *malicious* build were ever notarized,
Apple can revoke the signing certificate — contact Apple Developer Support; revoking invalidates
every build signed with that identity.

---

## 8. CI secrets and rotation

`.github/workflows/release.yml` is §4 run on a `macos-26` runner: everything above stays in
`scripts/make-dist.sh`, and the workflow only supplies the two things a laptop has and a runner
does not — a keychain holding the Developer ID identity, and a `notarytool` credential profile.
It needs seven repository secrets (Settings › Secrets and variables › Actions). `ci.yml`
(`swift build` + `swift test`) needs **none**, deliberately, so it stays runnable from a fork's
pull request.

`ci.yml` runs on every push and has been green for a while, which is what proves the `macos-26`
label and `/Applications/Xcode_26.1.app` (Xcode 26.1.1 on the image, symlinked at that path).
`release.yml` is triggered by a pushed `v*` tag, and by a manual dispatch — see *Verifying the
credentials* below for the dry run that exercises it without publishing.

| Secret | What it is |
|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` | base64 of the Developer ID Application certificate + private key, exported as a `.p12` **with its certificate chain** |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | the password typed when exporting that `.p12` |
| `APPLE_SIGN_IDENTITY` | the `Developer ID Application: … (TEAMID)` string of §1, passed to `make dist` as `SIGN_IDENTITY` |
| `ASC_API_KEY_P8_BASE64` | base64 of the App Store Connect API key `AuthKey_<KEYID>.p8` from §1 step 3 |
| `ASC_API_KEY_ID` | that key's 10-character Key ID |
| `ASC_API_ISSUER_ID` | the App Store Connect issuer UUID (one per team) |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT with **Contents: Read and write** on `tkz0/homebrew-tap` and nothing else |

`GITHUB_TOKEN` is not in that list: it is built in, and the workflow's `contents: write`
permission is what lets `make dist` run `gh release create` on this repository. The tap is a
different repository, which is why it needs a PAT of its own.

### Producing them

**Signing certificate.** Keychain Access › *login* › *My Certificates* › the *Developer ID
Application* entry › right-click › *Export…* › `.p12`. Export the **certificate** entry, not the
bare private key: a key without its certificate imports fine but `security find-identity -v -p
codesigning` lists nothing valid. The identity also needs its issuer, Apple's *Developer ID
Certification Authority* (G2) intermediate, which the workflow imports from apple.com on its own
rather than relying on the export having carried it. The import step re-runs that same
`find-identity` and greps for `Developer ID Application` precisely to catch a bad `.p12` in the
first minute rather than twenty minutes into a build. Prove the export locally first, in a
throwaway keychain:

```sh
security create-keychain -p x "$TMPDIR/probe.keychain-db"
security import DeveloperID.p12 -k "$TMPDIR/probe.keychain-db" -P "$P12_PASSWORD"
security find-identity -v -p codesigning "$TMPDIR/probe.keychain-db"   # → 1 valid identity
security delete-keychain "$TMPDIR/probe.keychain-db"
```

**Notarization key.** The `.p8` from §1 step 3; the key needs the **Developer** role or higher,
*Admin* is not required. It is downloadable **once** — losing it means issuing a new key. The Key
ID is in the file name (`AuthKey_<KEYID>.p8`) and in the App Store Connect key table; the Issuer
ID sits above that table and is the same for every key on the team. This key is independent of
whatever the development Mac's `tkzmux-notary` profile was made from; the two rotate separately.
Prove it before uploading:

```sh
xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
```

**Tap token.** github.com › Settings › Developer settings › *Personal access tokens* ›
*Fine-grained tokens* › *Generate new token*. Resource owner `tkz0`, **Only select repositories ›
`tkz0/homebrew-tap`**, Repository permissions › *Contents: Read and write*, expiry at most one
year (note the date; see *Rotation*). Nothing else, and never a classic token — a classic `repo`
token can write to every repository on the account.

**Setting them.** Pipe files through `gh secret set` so no value passes through a browser, a
clipboard, or a chat transcript. The two without a `--body`/stdin form prompt for the value.

```sh
R=tkz0/tkzmux
base64 -i DeveloperID.p12       | gh secret set APPLE_DEVELOPER_ID_P12_BASE64 -R $R
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD -R $R                    # prompts
gh secret set APPLE_SIGN_IDENTITY -R $R --body "$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_API_KEY_P8_BASE64 -R $R
gh secret set ASC_API_KEY_ID    -R $R --body XXXXXXXXXX
gh secret set ASC_API_ISSUER_ID -R $R --body 00000000-0000-0000-0000-000000000000
gh secret set HOMEBREW_TAP_TOKEN -R $R                                 # prompts
gh secret list -R $R                                                   # → all seven
```

Afterwards delete the `.p12` and `.p8` from disk. The private key behind the `.p12` still lives
in the login keychain; the `.p8` then exists only as the GitHub secret, so decide first whether
you want a copy in a password manager.

### On the runner

The keychain is created and destroyed inside the job, so no secret outlives it:

- A keychain in `$RUNNER_TEMP`, unlocked with an `openssl rand` password generated in-job (it only
  has to be unguessable for the life of the job, so it is *not* a stored secret).
- Apple's Developer ID G2 intermediate, fetched from apple.com and imported before the `.p12`, so
  the identity validates whether or not the export carried its chain.
- `security set-keychain-settings -lut 21600` — otherwise it auto-locks partway through a long
  notarization wait.
- Made the **default** keychain and put on the search list, then given a key partition list of
  `apple-tool:,apple:,codesign:` — without that, codesign blocks on a UI prompt for keychain
  access that nobody can answer.
- `notarytool store-credentials` is run with **no `--keychain`**, on purpose: `make notarize`
  reads the profile with `notarytool submit --keychain-profile` and no `--keychain` either, so
  storing and reading must share the same unqualified default. A `notarytool history` call right
  after proves the profile resolves exactly the way `make notarize` will.
- A final `if: always()` step restores the login keychain and deletes the temporary one.

Two runner-side steps have no equivalent on a laptop and are easy to lose in a refactor:
`fetch-depth: 0` on the checkout (§2 derives the version from `git describe` and
`git rev-list --count`; a shallow clone silently yields `0.0.0-dev+<sha>` and build 1), and
`xcodebuild -downloadComponent MetalToolchain` (Xcode 26 ships the Metal compiler separately, and
`make-app.sh` runs `xcrun metal` under `set -e`).

### Rotation

| Secret | Rotate when | How |
|---|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` + `…_PASSWORD` + `APPLE_SIGN_IDENTITY` | the certificate expires (5 years), is revoked, or the Mac holding the private key is retired | New certificate per §1 step 2, re-export with chain, update all three together — the identity string carries the team ID and changes if the team does. Already-notarized releases keep working: notarization outlives the signing certificate. |
| `ASC_API_KEY_P8_BASE64` + `ASC_API_KEY_ID` | yearly, on a team member leaving, or if the `.p8` was ever committed or pasted anywhere | Generate a new key, update both secrets, then **revoke the old key** in App Store Connect. |
| `ASC_API_ISSUER_ID` | only if the Apple Developer team changes | Copy the new UUID from App Store Connect. |
| `HOMEBREW_TAP_TOKEN` | at expiry — fine-grained PATs allow at most one year, so this **will** need rotating; also on any suspected leak | Generate a replacement with the same single-repository scope, update the secret, delete the old token. Symptom of an expiry: the tap-checkout step fails with a 404 on `tkz0/homebrew-tap`, before anything is built. |

### Verifying the credentials

Do not verify a rotation by cutting a real release. Push a throwaway prerelease tag whose message
opts out of the tag trigger, then dispatch the workflow against it with `dry_run`:

```sh
git tag -a v0.0.1-rc1 -m 'CI smoke test [skip release]'
git push origin v0.0.1-rc1
gh workflow run release.yml --ref v0.0.1-rc1 -f dry_run=true
gh run watch
```

The push proves the `[skip release]` gate in passing — the gate job reports `proceed=false` and
the macOS job is skipped — so no second throwaway tag is needed to test it.

`dry_run` sets `DIST_DRAFT=1` and clears `TAP_DIR`, so the run builds, signs, notarizes and
staples for real but publishes a **draft** release and leaves the cask alone. A draft is never
marked *Latest*, so `livecheck strategy :github_latest` cannot see it and no user can install it.

The three credentials fail early and distinguishably, all before the long build: a bad PAT at
*Clone the Homebrew tap* — at its `git push --dry-run`, not the clone itself, because the tap is
public and clones with any token or none — a bad `.p12` at *Import the Developer ID signing
identity*, bad ASC credentials at *Store notarytool credentials*. Afterwards:

```sh
gh release delete v0.0.1-rc1 --yes
git push origin :v0.0.1-rc1 && git tag -d v0.0.1-rc1
```

and confirm `tkz0/homebrew-tap` gained no commit.
