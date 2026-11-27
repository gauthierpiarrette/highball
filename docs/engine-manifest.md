# Engine manifest v0

An **engine** is an identified, architecture-specific Wine runtime assembled from a
manifest's checksum-pinned components into Highball's expected directory layout.
It includes a required Wine core and may include supporting libraries, renderer
overlays, patches and tools. An installed engine must contain the essential files
for its architecture. Bottles reference engines; renderer selections and recipes
configure their use.

The engine is the whole assembly, not just the Wine build. Two assemblies using the
same Wine archive can differ in their renderers, runtime libraries or base settings.
The component named `wine`, with `kind: "engine"`, supplies the Wine core. Component
`kind` classifies a component; its name and `extract` instructions determine how it
is installed.

## Contract and identity

The repository-owned [v0 JSON Schema](../schemas/engine-manifest-v0.schema.json)
describes the format. `$schema` in a manifest is an optional editor annotation;
Highball does not fetch it or require a format-version field. Both the app and CLI
enforce `EngineManifest.validate()` before any installation side effects. JSON
decoding itself remains permissive so older installed manifests stay readable.
CI checks the shipped manifests against both the schema and Swift validation.

Required fields are `id`, `displayName`, `arch`, `minMacOS` and `components`:

| Field | Contract |
| --- | --- |
| `id` | Starts with an ASCII letter or digit; remaining characters are letters, digits, `.`, `_` or `-`. Labels the complete assembly. |
| `displayName` | Nonblank human-readable name. |
| `arch` | `x86_64` or `arm64`, describing Wine's Unix side. Bottles switch only within one architecture. |
| `minMacOS` | One to three numeric components, such as `14`, `14.0` or `26.5.1`, each representable as a Swift `Int`. Installation separately checks this Mac's version. |
| `components` | A map of safe component names to component definitions, including a required `wine` entry. |

`wine` must have `kind: "engine"`, must not be optional, and must have
`extract.into: "engine"`. Runtime libraries and renderers need not be separate
components if they are already bundled in the Wine archive. A renderer-only or
patch-only manifest is not a complete engine and cannot be installed as one.

Custom app imports must use an ID that is neither bundled nor already installed.
The CLI and normal installer retain replacement behavior for repairs. Authors
should publish a new ID when changing the assembly; IDs are labels, not content
hashes, and replacement does not enforce immutability. The conventional `-rN`
suffix is used for line/revision comparisons; it is not required for custom IDs
and does not itself prove compatibility.

## Components and assembly

Each component requires `kind`, `url` and `sha256`. Supported kinds are `engine`,
`frameworks`, `runtime`, `renderer`, `patch` and `tool`. Sources may be third-party
HTTP/HTTPS URLs with a host or absolute local `file://` URLs with an empty host or
`localhost`. Checksums must be 64 hexadecimal characters (either case); downloaded
and local bytes are verified against them. Optional `size` is a nonnegative byte
count used for progress, not an independent integrity check.

`extract.into` is a directory or a single-file destination relative to the engine
root. `extract.subpath` selects a source within the archive; the legacy `strip`
field serves the same purpose, with `subpath` taking precedence when both exist.
All three paths must be nonempty, relative, and contain no backslash, NUL or `..`
segment. Without `extract`, a component is copied as an executable plain file into
`tools/`. The installer may replace a single file but refuses to replace an
already populated directory with another directory component.

Components install in deterministic order: required before optional, then ascending
`order` (default `0`), then name. `optional` defaults to false. Optional components
with `acceptance` download only when that license ID was explicitly accepted;
other optional components follow the installer's `includeOptional` setting.
Imported `acceptedLicenses` never grants consent: installation records requested
acceptances and those already accepted locally. D3DMetal also retains its runtime
license gate.

The installed root is `engines/<id>/`, normally containing:

```text
manifest.json         Installed manifest and locally recorded license acceptances
engine/bin/           Wine and wineserver
engine/lib/wine/      Architecture-specific Unix and PE builtins
frameworks/           Supporting host libraries and frameworks, when supplied
renderers/<name>/     Renderer overlays, when supplied
tools/                Plain-file tools, when supplied
```

Components can add other subdirectories, such as `x87sidecar/`. The runtime's
renderer lookup and architecture-specific library conventions still apply.

## Runtime settings and descriptive metadata

`baseEnv` supplies process environment values; `${frameworks}` and `${renderers}`
expand to installed paths. `appDefaults` supplies per-executable Wine registry
string values. `rendererAppDefaults` supplies the same executable/value maps keyed
by renderer mode; its values override `appDefaults` for that launch. For example,
Wine 11 uses it to give `steamwebhelper.exe` `--in-process-gpu` under D3DMetal
and DXMT. Switching modes updates the registry and removes values supplied only
by another mode. `direct3D9: "wined3d"` keeps Direct3D 9 with Wine in automatic
renderer modes. `requires` includes `rosetta2` when needed. `channel` controls
catalog visibility (`beta` or `preview`, omitted for everyone); explicit custom
imports do not require channel opt-in. `refreshesPrefix` on a changed component
requests prefix setup again even when the Wine checksum has not changed.

`license`, `version`, `note`, `notes` and `licenses` provide attribution, descriptions
and license text. `acceptedLicenses` is installed state. `layout`, `provides`,
`verified`, `alternatives`, component `env` and `replacesTemplateRenderer` are
informational fields ignored by the current Swift model. In particular, `layout`
can contain globs and prose: it is not a machine-checked file inventory. Use
top-level `baseEnv` for environment values that should affect execution.

Unknown fields remain accepted for v0 compatibility; acceptance does not imply
support for new behavior. Fields outside the Swift model are not preserved when
the installer saves its manifest. The schema checks JSON structure, while Swift
also checks parsed URL semantics and that version components fit `Int`.

## Installation checks and their limits

Before committing the staged engine, installation checks `engine/bin/wine`,
`engine/bin/wineserver`, 64-bit `kernel32.dll` and `ntdll.dll`, 32-bit
`kernel32.dll`, and Unix `ntdll.so`. Intel libraries use `x86_64-windows` and
`x86_64-unix`; arm64 uses `aarch64-windows` and `aarch64-unix`, with
`i386-windows` shared by both. Arm64 also requires `xtajit64.dll`, `xtajit.dll`,
`libarm64ecfex.so` and `libwow64fex.so`, and Highball's signed Wine loader. An
incomplete staging tree is discarded before an existing engine is replaced.

These checks establish a minimum expected layout and archive integrity. They do
not execute Wine, verify every dependency or certify game compatibility.
`verified` records human evidence rather than conferring runtime certification.

To check source manifests without downloading engine archives:

```sh
uv run --with jsonschema==4.25.1 python Scripts/validate-engine-manifests.py
swift test --filter BundledEngineTests
```

The schema script also accepts individual manifest paths. Publishing the schema
at its `$id` URL is a separate hosting task; repository validation uses the local
file and never depends on that URL being reachable.
