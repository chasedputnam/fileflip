# Tasks — Packaged media conversions

Approved by: Product owner
Date: 2026-07-29
Status: approved

#[[file:requirements.md]]
#[[file:design.md]]

- [x] 1. Canonicalize and verify the checked-in media tool configuration
  - References: Requirements 1.3, 1.7, 2.1, 2.3–2.4, 7.1
  - [x] 1.1 Add version-controlled positive and negative configuration-token fixtures covering quoted lists, paths with spaces, escapes, duplicate/forbidden flags, malformed quoting, and semantically distinct arguments.
  - [x] 1.2 Update `scripts/generate-media-manifest.py` to emit the canonical unquoted argument array and its newline-joined SHA-256 using a strict bounded lexer.
  - [x] 1.3 Update `MediaToolVerification.swift` to parse observed FFmpeg and ffprobe configuration into the same canonical representation without executing a shell.
  - [x] 1.4 Add Python and Swift contract tests against the shared fixtures and verifier tests proving equivalent quoting passes while different, forbidden, or malformed configuration fails.
  - [x] 1.5 Regenerate the checked-in manifest from the pinned signed binaries and run strict `MediaToolVerifier` verification against `Sources/FileConvertApp/Resources/MediaTools` with signature checks enabled.

- [x] 2. Preserve and discover the complete `MediaTools` application resource directory
  - References: Requirements 1.1–1.6, 2.2, 6.1, 8.1
  - [x] 2.1 Change `scripts/generate-project.rb` to copy `MediaTools` as one directory at `Contents/Resources/MediaTools` rather than flattening individual resource files, then regenerate `FileFlip.xcodeproj`.
  - [x] 2.2 Add a build-layout verifier that rejects missing directories, flattened artifacts, missing licenses, non-executable tools, unexpected top-level media files, and unsafe links.
  - [x] 2.3 Add `BundledMediaToolsLocator` with canonical resource-root containment, no environment or `PATH` fallback, and injectable bundle/directory inputs limited to tests.
  - [x] 2.4 Add `PackagedMediaBootstrap`, route `ConcreteApplicationRuntime` through it, and preserve independent initialization of non-media providers when packaged media verification fails.
  - [x] 2.5 Add locator/bootstrap tests for relocation, missing and flattened resources, containment failures, zero-capability failure behavior, and successful verification from a built `.app`.
  - [x] 2.6 Build the Xcode application and run the layout verifier plus strict packaged bootstrap against the produced app bundle.

- [x] 3. Establish one authoritative installed audio/video capability contract
  - References: Requirements 3.1–3.6, 4.1–4.8, 6.2, 7.3–7.4, 8.6
  - [x] 3.1 Add `InstalledMediaFormat` and `InstalledMediaContract` with the exact eight audio and five video formats, canonical extensions, aliases, required encoders/muxers, admitted codecs, default policies, and contract version.
  - [x] 3.2 Replace the private provider target/source tables with contract-derived same-family, non-identity capabilities and command mappings.
  - [x] 3.3 Replace duplicate runtime and probe extension/container switches with contract lookups, preserving raw AAC versus M4A, MP4 versus M4V versus MOV, AIFF aliases, Matroska, and WebM distinctions.
  - [x] 3.4 Keep approved hardware video encoding optional while requiring and selecting the packaged software fallback when hardware encoding is absent or fails.
  - [x] 3.5 Add exact-set contract tests proving 13 logical formats, 56 audio routes, 20 video routes, no identity/cross-family routes, correct codec/muxer requirements, and target distinctions.
  - [x] 3.6 Update existing provider, detector, runtime, and validator tests to consume the shared contract and remove obsolete duplicated mappings.

- [x] 4. Expose bounded independent media facts for certification
  - References: Requirements 3.3–3.4, 4.3–4.7, 5.2–5.4, 6.7–6.8
  - [x] 4.1 Add Codable `MediaFacts` and `MediaStreamFacts` models for logical format, duration, stream kind, codec, frame evidence, sample rate, channels, width, and height.
  - [x] 4.2 Extend `FFprobeMediaValidator` to parse bounded facts, reject malformed/non-finite/negative/contradictory values, and enforce target-specific admitted codecs and stream contracts from `InstalledMediaContract`.
  - [x] 4.3 Preserve production validation behavior while returning normalized facts needed by fixture certification and matrix evidence.
  - [x] 4.4 Add validator tests for every logical container distinction, exact stream counts, positive duration/frame evidence, audio properties, video dimensions, malformed probe output, undecodable streams, and filename/exit-status-only false positives.

- [x] 5. Build the certified per-format source fixture system
  - References: Requirements 5.1–5.7, 6.3–6.5, 8.2–8.3
  - [x] 5.1 Define a strict media fixture-manifest schema with exact logical format set, safe relative paths, hashes, lengths, provenance, licenses, generator identity, expected facts, and pre-agreed numeric tolerances.
  - [x] 5.2 Implement `scripts/generate-media-fixtures.py` with a pinned synthetic non-silent audio/changing-video recipe, isolated staging, atomic publication, and `FILECONVERT_UPDATE_FIXTURES=1 --update` write protection.
  - [x] 5.3 Generate and check in one minimal source fixture for each of MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus, MP4, M4V, MOV, Matroska, and WebM plus its certified manifest record.
  - [x] 5.4 Extend fixture checking to reject unknown fields, duplicate/missing/extra formats, unsafe paths, size/hash drift, invalid provenance/license data, and fact mismatches observed through packaged ffprobe.
  - [x] 5.5 Add tests proving compare-only runs never rewrite fixture bytes or records, guarded regeneration is atomic, malformed inventories fail, and all 13 checked-in fixtures certify successfully.

- [x] 6. Implement deterministic candidate and route-set evidence models
  - References: Requirements 6.2, 6.10–6.11, 8.3–8.4
  - [x] 6.1 Implement deterministic candidate bundle hashing over sorted contained regular files, relative paths, executable modes, byte lengths, and file hashes; reject symlinks and path escapes.
  - [x] 6.2 Implement deterministic normalized route-set serialization and hashing shared by the matrix runner and release gate.
  - [x] 6.3 Define strict Codable matrix-report models containing application/provider identity, platform, contract and manifest hashes, exact route counts, fixture/source/output hashes, observed facts, and per-route results.
  - [x] 6.4 Add strict decoding, unknown-field rejection, duplicate-route rejection, atomic report writing, stable-ordering, and candidate/manifest binding tests.

- [x] 7. Execute and validate every packaged media conversion route
  - References: Requirements 3.2–3.6, 4.2–4.8, 6.1–6.11, 8.2–8.5
  - [x] 7.1 Add the non-shipping `packaged-media-matrix` Swift executable target with required `--app`, `--fixtures`, and `--report` arguments and no skip semantics.
  - [x] 7.2 Load tools through production packaged bootstrap, certify all fixtures, assert the exact capability set, and order all routes deterministically.
  - [x] 7.3 For each of the 56 audio routes, use the fixture for the actual source format, run the production provider with its default policy, and independently validate the requested target facts.
  - [x] 7.4 For each of the 20 video routes, use the fixture for the actual source format, run the production provider with its default policy, verify admitted container/codecs, and require exactly one decodable video plus one decodable audio stream.
  - [x] 7.5 Before and after every route, assert unchanged source path, byte length, SHA-256, and certified facts; assert one bounded regular output in the assigned job directory and no partial/additional provider output.
  - [x] 7.6 Fail the command on any missing, unexpected, duplicate, skipped, timed-out, source-mutating, conversion-failing, or output-invalid route; emit a passing report only at 76/76 executed and passed with zero skips/failures.
  - [x] 7.7 Build an application candidate and run the complete matrix, preserving its machine-readable report as evidence that all 76 packaged routes pass.

- [x] 8. Complete fail-closed media package and execution boundary coverage
  - References: Requirements 2.1–2.7, 7.1–7.4
  - [x] 8.1 Add real copied-bundle tamper tests for missing artifacts/licenses, executable-mode removal, symlinks, traversal, malformed/unknown manifest fields, modified artifact hashes, and removed/invalid signatures.
  - [x] 8.2 Add bounded-runner seam tests for wrong architecture, inspection timeout, FFmpeg/ffprobe version disagreement, configuration mismatch, forbidden GPL/nonfree flags, inventory mismatch, and failed startup self-test.
  - [x] 8.3 Assert every verification failure returns no `VerifiedMediaTools`, registers zero FFmpeg capabilities, preserves unaffected provider initialization, and never executes sentinel ambient media tools.
  - [x] 8.4 Cover unsupported identity/cross-family/extension routes, invalid policy versions/ranges, output-directory escape, pre-existing output, deadline, timeout, cancellation, output-size limits, nonzero process exit, partial-output cleanup, and hardware-to-software fallback.
  - [x] 8.5 Run the focused verifier/provider negative suites and confirm every listed failure remains fail-closed.

- [x] 9. Add relocated installed-application media smoke coverage
  - References: Requirements 1.1, 1.4, 1.6–1.7, 7.5, 7.7
  - [x] 9.1 Add a macOS smoke harness that copies the app candidate to a clean temporary installation location and initializes the production locator/bootstrap in a sanitized environment.
  - [x] 9.2 Place sentinel `ffmpeg` and `ffprobe` commands on the ambient `PATH`, observe packaged provider availability, and assert the sentinels are never invoked.
  - [x] 9.3 Complete one audio and one video conversion through production-facing components, independently validate both outputs, and verify unchanged sources.
  - [x] 9.4 Add the smoke command to the Xcode/release verification surface and run it against the same candidate used by the exhaustive matrix.

- [x] 10. Enforce packaged media evidence in release readiness
  - References: Requirements 2.6, 6.10–6.11, 7.6, 8.1–8.6
  - [x] 10.1 Extend `release/release-contract.json` with the media contract version, exact format/route counts, fixture policy, matrix command, installation-smoke command, report schema, and required candidate/manifest identities.
  - [x] 10.2 Update `scripts/release-readiness.py` to inspect candidate-bundle media resources, validate fixture and report schemas strictly, enforce 56 audio plus 20 video routes with zero skips/failures, and compare candidate, manifest, route-set, revision, platform, and date evidence.
  - [x] 10.3 Preserve and exercise nested Mach-O signature, arm64, Hardened Runtime, forbidden-entitlement, authorized-framework, notarization, and Gatekeeper checks for the final candidate.
  - [x] 10.4 Add release-gate tests proving flattened resources, stale/different candidate reports, source-tree-only results, unsigned results, missing routes, substituted routes, skipped routes, and fixture regeneration drift all block readiness.
  - [x] 10.5 Add a contract-export/consistency check for application and site capability declarations, then update only declarations that differ from `InstalledMediaContract`.

- [x] 11. Run the complete packaged-media verification stack
  - References: Requirements 1.1–1.7, 2.1–2.7, 3.1–3.6, 4.1–4.8, 5.1–5.7, 6.1–6.11, 7.1–7.7, 8.1–8.6
  - [x] 11.1 Run unit and contract suites for configuration parsing, installed capability mapping, strict schemas, media facts, command boundaries, candidate identity, and route identity.
  - [x] 11.2 Run strict fixture certification for all 13 source formats and the complete verifier tamper/negative suites.
  - [x] 11.3 Build and sign the arm64 application, verify the exact installed resource layout and nested signatures, then run the relocated installation smoke.
  - [x] 11.4 Run the 76-route packaged matrix against that same application and require 56/56 audio plus 20/20 video passes, zero skips/failures, zero source mutations, and zero ambient tool executions.
  - [x] 11.5 Run all existing non-media regression suites and the canonical release-readiness command against the same candidate/evidence; record exact commands and observed results without claiming Intel, LibreOffice, exhaustive policy, or production coverage.
