# Requirements — Packaged media conversions

Approved by: Product owner
Date: 2026-07-29
Status: approved

## Introduction

FileFlip advertises audio and video conversions as built-in capabilities, but an installed application must not depend on Homebrew, a user-managed `PATH`, network downloads, or separately installed media providers. The distributable application must carry its approved FFmpeg toolchain and codec dependencies, verify that exact bundle before registering media capabilities, and fail closed if the bundle is incomplete or altered.

The feature also needs release-grade evidence for every audio-to-audio and video-to-video file-type conversion available immediately after installation. Evidence must begin with certified source fixtures, exercise the packaged release candidate rather than source-tree tools, independently validate every produced artifact, and prove that conversion does not mutate the source.

## Scope priorities

### Must have

- Package FFmpeg, ffprobe, required codec implementations, provider manifest, and license notices inside the macOS application.
- Make all packaged audio and video capabilities available on first launch without an external media installation.
- Verify packaged media tools before registering any FFmpeg capability and fail closed on any verification error.
- Support and test every directed, non-identity conversion within the installed audio and video format families.
- Certify every source fixture before use and independently validate every conversion output.
- Run the complete matrix against the media tools extracted from the final built application bundle.
- Make zero skipped, missing, unexpected, or failed matrix routes a blocking release condition.

### Should have

- Produce a machine-readable conversion-matrix report suitable for release evidence and diagnosis.
- Keep source fixtures deterministic, minimal, attributable, and reproducible from a reviewed command.
- Keep the matrix derived from one authoritative installed-capability contract so implementation, tests, documentation, and release checks cannot drift independently.

### Out of scope

- LibreOffice installation, packaging, document conversions, spreadsheet conversions, or LibreOffice compatibility testing.
- Image, PDF, Markdown, or HTML provider changes except where shared release infrastructure must continue to pass.
- Intel (`x86_64`) support or a universal media-tool bundle; this phase targets the existing Apple Silicon deployment contract.
- Cross-family audio-to-video, video-to-audio, or media-to-document conversions.
- Identity conversions where source and target are the same logical format.
- Exhaustive Cartesian testing of every bitrate, sample-rate, quality, track-selection, subtitle-selection, metadata, or hardware-encoder policy value. This phase proves every supported file-type route using its installed default policy; policy boundary behavior remains covered by focused tests.
- Downloading, updating, or repairing media dependencies after installation.

## Requirement 1 — Self-contained installed media provider

**User Story:** As a user, I want audio and video conversion to work immediately after installing FileFlip, so that I do not need to discover or install command-line dependencies.

### Acceptance Criteria

1.1 WHEN FileFlip is installed on a supported Apple Silicon macOS system with no Homebrew installation, no system FFmpeg installation, and no network access THEN the application SHALL make its approved audio and video conversion routes available from its packaged dependencies.

1.2 The application bundle SHALL contain executable FFmpeg and ffprobe artifacts, all non-system runtime dependencies required by the approved codec inventory, the provider manifest, and all required license notices under one stable media-tools resource directory.

1.3 The packaged FFmpeg and ffprobe artifacts SHALL NOT require a non-system dynamic library, executable, environment variable, user-home file, or writable installation-directory resource to start or convert supported media.

1.4 WHEN FileFlip launches THEN it SHALL resolve media tools only from its own application bundle and SHALL NOT discover or execute an ambient `ffmpeg` or `ffprobe` through `PATH`.

1.5 WHEN the packaged provider passes verification THEN the application SHALL register exactly the media capabilities allowed by the verified manifest and codec inventory.

1.6 WHEN the application is copied to another location or launched from a standard installed location such as `/Applications` THEN packaged media discovery and capability registration SHALL continue to work without rewriting absolute build-machine paths.

1.7 The packaged provider SHALL operate with network protocols disabled and SHALL complete supported local-file conversions without network access.

## Requirement 2 — Fail-closed package verification

**User Story:** As a user, I want FileFlip to reject incomplete or altered media tooling, so that an untrusted or incompatible executable is never used on my files.

### Acceptance Criteria

2.1 BEFORE registering any packaged audio or video capability, the application SHALL verify the media resource directory, strict manifest shape, artifact names and containment, executable file type, cryptographic hashes, code signatures, supported architecture, FFmpeg/ffprobe version agreement, approved build configuration, codec inventory, and bounded startup self-test.

2.2 IF the media directory, manifest, executable, license inventory, required codec, required muxer, or required demuxer is missing THEN the application SHALL register no FFmpeg conversion capability and SHALL report the local provider as unavailable.

2.3 IF a packaged artifact hash, signature, architecture, version, configuration, or observed inventory differs from its manifest THEN the application SHALL register no FFmpeg conversion capability and SHALL NOT fall back to an ambient executable.

2.4 IF manifest configuration has a semantically equivalent quoted or escaped representation THEN generation and verification SHALL canonicalize it consistently before comparison; semantically different configuration SHALL still be rejected.

2.5 IF any manifest path is absolute, traverses outside the media resource directory, names a symlink, or resolves to a non-regular file THEN verification SHALL reject the entire packaged provider.

2.6 WHEN a local development build is produced THEN its nested media executables SHALL carry valid signatures accepted by the verifier, and WHEN a distributable build is produced THEN its nested media executables SHALL be signed consistently with the Developer ID application and accepted by macOS code-signing and notarization assessment.

2.7 WHEN provider verification fails THEN image, PDF, native document, application startup, and settings access SHALL remain available, while audio and video routes SHALL remain unavailable with a user-visible provider status.

## Requirement 3 — Installed audio conversion contract

**User Story:** As a user, I want every advertised audio format to convert to every other advertised audio format, so that the installed capability list is complete and truthful.

### Acceptance Criteria

3.1 The installed audio format contract SHALL contain exactly these logical formats and canonical target extensions: MP3 (`mp3`), M4A (`m4a`), AAC (`aac`), WAV (`wav`), AIFF (`aiff`), FLAC (`flac`), OGG Vorbis (`ogg`), and Opus (`opus`).

3.2 WHEN packaged verification succeeds with the approved inventory THEN the application SHALL advertise every directed non-identity route among the eight audio formats, totaling 56 audio conversion routes.

3.3 WHEN any of the 56 audio routes is executed with its installed default policy and a certified source fixture THEN conversion SHALL succeed without mutating the source and SHALL produce one independently validated artifact of the requested logical target format.

3.4 WHEN the requested target is AAC or M4A THEN routing and output validation SHALL preserve the distinction between raw ADTS AAC and M4A-contained AAC.

3.5 WHEN an accepted alias extension identifies a supported audio type, including `aif` for AIFF, THEN content detection and route selection SHALL resolve it to the same logical source format without adding a duplicate logical matrix route.

3.6 IF the verified codec inventory cannot encode or mux any required audio target THEN the application SHALL omit all routes to that target and the release matrix gate SHALL fail because the installed contract is incomplete.

## Requirement 4 — Installed video conversion contract

**User Story:** As a user, I want every advertised video format to convert to every other advertised video format, so that installed video conversion behaves consistently across supported containers.

### Acceptance Criteria

4.1 The installed video format contract SHALL contain exactly these logical formats and canonical target extensions: MP4 (`mp4`), M4V (`m4v`), MOV (`mov`), Matroska (`mkv`), and WebM (`webm`).

4.2 WHEN packaged verification succeeds with the approved inventory THEN the application SHALL advertise every directed non-identity route among the five video formats, totaling 20 video conversion routes.

4.3 WHEN any of the 20 video routes is executed with its installed default policy and a certified source fixture THEN conversion SHALL succeed without mutating the source and SHALL produce one independently validated artifact of the requested logical target format.

4.4 WHEN the requested target is MP4, M4V, or MOV THEN routing and output validation SHALL preserve the requested logical container distinction wherever the installed contract distinguishes those formats.

4.5 WHEN a default video conversion processes a certified source containing one video stream and one audio stream THEN the output SHALL contain exactly one decodable video stream and one decodable audio stream unless the route contract explicitly states otherwise.

4.6 WHEN WebM is the target THEN the output SHALL use codecs admitted by the installed WebM contract, and WHEN MP4, M4V, MOV, or Matroska is the target THEN the output SHALL use codecs admitted by that target's installed contract.

4.7 IF a preferred hardware video encoder is unavailable or fails for a supported route THEN the application SHALL use its packaged approved software fallback and SHALL still satisfy the same output validation contract.

4.8 IF the verified codec inventory cannot encode or mux any required video target THEN the application SHALL omit all routes to that target and the release matrix gate SHALL fail because the installed contract is incomplete.

## Requirement 5 — Certified source fixture suite

**User Story:** As a maintainer, I want each matrix input to be demonstrably valid before conversion, so that a failed route cannot be confused with a malformed or mislabeled source fixture.

### Acceptance Criteria

5.1 The test suite SHALL provide at least one deterministic source fixture for each of the eight logical audio formats and each of the five logical video formats in Requirements 3.1 and 4.1.

5.2 Each fixture SHALL have a reviewed fixture record containing its logical format, canonical extension, SHA-256 hash, byte length, expected container facts, expected stream types and counts, expected codecs, and bounded duration; video records SHALL additionally include expected dimensions and frame evidence, and audio records SHALL additionally include expected channel and sample-rate facts.

5.3 BEFORE a fixture participates in a conversion test run, the suite SHALL verify its hash and byte length and SHALL independently probe its media facts against its fixture record.

5.4 IF a fixture is missing, mislabeled, hash-mismatched, empty, structurally invalid, undecodable, outside its duration bound, or inconsistent with its recorded stream facts THEN the suite SHALL fail before reporting any dependent conversion route as tested.

5.5 Fixture generation SHALL be deterministic from a version-controlled command and pinned input recipe, and regeneration SHALL require an explicit opt-in that updates fixture bytes and fixture records for review.

5.6 The fixture set SHALL contain only synthetic or redistributable media with recorded provenance and license terms compatible with repository and release use.

5.7 Audio source fixtures SHALL contain a non-silent deterministic signal, and video source fixtures SHALL contain deterministic changing video content plus a non-silent audio signal, so successful validation cannot be satisfied by an empty container or zero-content stream.

## Requirement 6 — Exhaustive packaged conversion matrix

**User Story:** As a release owner, I want machine-checkable evidence for every installed media route, so that no advertised conversion ships based on a representative sample alone.

### Acceptance Criteria

6.1 FOR EACH release candidate, the matrix suite SHALL discover FFmpeg, ffprobe, manifest, and licenses from that candidate's built `.app` resource directory rather than from the source tree, a build-work directory, or `PATH`.

6.2 BEFORE conversions begin, the suite SHALL assert that the verified provider advertises exactly the 56 audio routes and 20 video routes defined by Requirements 3 and 4, with no missing, duplicate, cross-family, identity, or unexpected route.

6.3 FOR EACH advertised audio route, the suite SHALL use the certified fixture matching that route's source logical format and execute the conversion through the production packaged provider with its installed default policy.

6.4 FOR EACH advertised video route, the suite SHALL use the certified fixture matching that route's source logical format and execute the conversion through the production packaged provider with its installed default policy.

6.5 BEFORE and after each conversion, the suite SHALL verify that the source path, SHA-256 hash, byte length, and certified media facts are unchanged.

6.6 AFTER each conversion, the suite SHALL verify that exactly one bounded, nonempty regular output artifact exists inside the assigned job directory and that no partial or additional provider output was published.

6.7 AFTER each conversion, an independent output probe SHALL verify the requested logical container, admitted codecs, exact selected stream counts, decodability with positive frame or duration evidence, nonzero bounded duration, and applicable audio sample/channel or video dimension facts.

6.8 IF output probing relies only on the filename extension, provider exit status, nonzero byte length, or successful decoding without confirming the requested container and stream contract THEN the route SHALL NOT count as verified.

6.9 The suite SHALL execute all 76 required routes with zero conditional skips; one fixture failure, missing route, unexpected route, conversion error, source mutation, timeout, size-bound violation, or output-validation error SHALL fail the complete matrix.

6.10 WHEN the complete matrix succeeds THEN the suite SHALL emit a machine-readable report containing the application identity, media manifest hash, FFmpeg version, architecture, route inventory, fixture hashes, source and target for each route, observed output facts, per-route result, total expected routes, total executed routes, and zero skipped routes.

6.11 The matrix report SHALL NOT be accepted as release evidence unless its application and media manifest hashes match the exact release candidate submitted to subsequent signing or notarization gates.

## Requirement 7 — Negative, boundary, and installation tests

**User Story:** As a maintainer, I want failures around packaging and media execution exercised deliberately, so that a green conversion matrix does not hide fail-open behavior.

### Acceptance Criteria

7.1 Automated tests SHALL verify rejection of a missing media directory, missing artifact, non-executable artifact, symlink artifact, path traversal, malformed manifest, unknown manifest field, hash mismatch, invalid signature, wrong architecture, FFmpeg/ffprobe version disagreement, forbidden GPL/nonfree configuration, configuration mismatch, inventory mismatch, startup timeout, and failed startup self-test.

7.2 Automated tests SHALL verify that each rejection in Requirement 7.1 registers zero FFmpeg capabilities and never executes an ambient media tool.

7.3 Automated tests SHALL verify command construction and rejection boundaries for unsupported cross-family and identity routes, invalid target extensions, invalid policy versions and ranges, output-directory escape, pre-existing output, deadline expiration, timeout, cancellation, output-size bounds, and nonzero FFmpeg termination.

7.4 Automated tests SHALL verify target routing and independent validation for extension/container distinctions including AAC versus M4A, MP4 versus M4V versus MOV, AIFF aliases, Matroska, and WebM.

7.5 WHEN a locally signed application is built and copied to a clean temporary installation location THEN an installation smoke test SHALL launch or initialize its production runtime with a sanitized environment, observe FFmpeg provider availability, and complete at least one audio and one video conversion using only bundled dependencies.

7.6 WHEN the release candidate is assessed THEN the release gate SHALL verify nested code signatures, Hardened Runtime compatibility, absence of unauthorized embedded executable code, notarization status where required, and successful packaged media verification.

7.7 Existing non-media provider suites SHALL continue to pass, and LibreOffice absence SHALL NOT cause the packaged audio/video matrix to skip or fail.

## Requirement 8 — Release gating and evidence integrity

**User Story:** As a release owner, I want media availability and exhaustive conversion evidence enforced by the release process, so that an installer cannot be published with silently unavailable or partially working media routes.

### Acceptance Criteria

8.1 The canonical release-readiness command SHALL fail unless the final application bundle preserves the required media-tools directory layout and all packaged artifacts are executable and verifiable in place.

8.2 The canonical release-readiness command SHALL fail unless fixture certification, exact capability-set comparison, all 76 conversion routes, source-integrity checks, output validations, and installation smoke tests complete successfully against the candidate application.

8.3 The release gate SHALL treat skipped tests, skipped routes, stale reports, fixture regeneration without reviewed record changes, or evidence generated from a different application or manifest hash as failures.

8.4 The release evidence contract SHALL record the exact command, execution environment, date, code revision, application hash, manifest hash, observed route counts, and matrix-report location.

8.5 WHEN release evidence cannot be produced on the final signed and notarized candidate THEN the release SHALL remain blocked rather than substituting source-tree, mocked, representative-route, or unsigned-build results.

8.6 The website, README capability table, and in-application availability state SHALL NOT claim an installed media route that is absent from the authoritative packaged capability contract.

## Success criteria

- A supported Apple Silicon Mac with no external FFmpeg installation exposes packaged audio and video conversion immediately after installing and launching FileFlip.
- The installed provider advertises exactly 56 audio and 20 video directed non-identity routes.
- All 76 routes pass against certified per-format sources using the exact media tools in the built application bundle.
- Every route proves unchanged source bytes and facts, plus a bounded, independently validated output with the requested logical container and stream contract.
- Tampered, incomplete, incompatible, or unverifiable media bundles expose zero FFmpeg capabilities and never fall back to ambient tools.
- Release readiness cannot pass with a flattened resource layout, configuration-normalization mismatch, missing route, skipped route, stale evidence, or report from a different application candidate.
- LibreOffice is neither packaged nor required for any result in this specification.
