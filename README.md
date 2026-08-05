# DesignlessKit

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-0A0A0A)](https://swift.org/package-manager)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9%2B-0A0A0A)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-0A0A0A)](https://github.com/designlesshq/designless-swift)
[![Dependencies](https://img.shields.io/badge/dependencies-none-0A0A0A)](#install)
[![License](https://img.shields.io/badge/license-Apache--2.0-0A0A0A)](LICENSE)

Your brand in an iOS, macOS, tvOS, watchOS or visionOS app. Colours, type, spacing and marks come from your published brand, and change when you publish.

This package carries no brand data. It is a client for the addresses your brand is served at, plus the rules Core Text needs followed before a downloaded typeface will appear on a screen.

**No dependencies.** HTTP is injected, so the package has no opinion about the networking an app already uses, and it drives from a test with no network at all.

## Install

```swift
.package(url: "https://github.com/designlesshq/designless-swift", from: "0.1.0")
```

## Use

```swift
import DesignlessKit

let brand = Brand(
    publicID: "r_XXXX",
    fetch: { url in try await URLSession.shared.data(from: url).0 },
    store: UserDefaultsSnapshotStore()      // optional, but shows the brand on the first frame
)

try await brand.initialize()

await brand.tokens?.color("bg.page")                 // "#060608"
await brand.tokens?.length("typography.fontSize.md") // 14.56
try await brand.assetURL("logo-symbol", format: .png, size: .px256)
```

With a `store`, the last payload is already showing before `initialize()` is awaited — the initialiser restores it synchronously. Without one, the first frame is unbranded, and that frame is the one a person judges the app by.

## Fonts

A downloaded typeface does not appear because you downloaded it. It appears because Core Text registered it **and** something asked for it by the right name. Get either wrong and nothing throws.

**A face is reached by its PostScript name.** Not because the family name fails — because it succeeds, at the wrong weight, every time. Measured against the real font manager with both Inter faces registered:

```
ask "Inter"           ->  Inter-Regular
ask "Inter-Regular"   ->  Inter-Regular
ask "Inter-SemiBold"  ->  Inter-SemiBold
```

`UIFont(name:size:)`, `Font.custom(_:size:)` and `CTFontCreateWithName` all take a name and no weight. Ask for `Inter` because your heading wants SemiBold and you get Regular: a real font, correctly rendered, quietly the wrong one. The only tell is that the headings look light.

**Register before you render.** A `UILabel` that has already sized itself does not re-lay-out because a font arrived afterwards, so a view built during the download keeps the system font for its whole life. `FontStaging` will not hand you a face whose file is not staged:

```swift
let staging = FontStaging(
    fetch: { url in try await URLSession.shared.data(from: url).0 }
)

await staging.stage(try await brand.loadFonts())     // download, cache, register

let body = await staging.resolve("body", weight: 600)
if let name = body.postscriptName {
    label.font = UIFont(name: name, size: 17)
} else {
    print(body.detail!)      // says which of six things happened
}
```

| outcome | what it means |
|---|---|
| `resolved` | a face was found and Core Text can reach it |
| `substituted` | a face was found, but not the weight or style you asked for |
| `notLoaded` | the font list has not been read — a fetch to retry |
| `unpublished` | no face for this role, and the roles that do exist are named |
| `tooFar` | the family publishes nothing within 200 of the weight asked for |
| `notRegistered` | a face exists but its file is not staged — a build to fix |

Substitution is reported rather than passed off as a match. A family publishing only Light, answering a request for Medium, looks exactly like a font that was applied.

### How registration works

Registration goes through `CTFontManagerRegisterFontsForURL`, which is current on every Apple platform. The bytes are written to disk first — no cost, since they are being cached anyway — and the PostScript name baked into the file is checked against the one the brand advertises before anything is registered. A file that disagrees is refused at that moment rather than missing every lookup later.

If you are hand-rolling this: `CTFontManagerRegisterGraphicsFont` is deprecated on macOS 15, and the replacement its notice suggests — `CTFontManagerCreateFontDescriptorsFromData` plus `CTFontManagerRegisterFontDescriptors` — **does not work for runtime-downloaded fonts**. At process scope with descriptors built from in-memory data it reports `CTFontManagerErrorDomain` code 303 and registers nothing, so every lookup falls through to the system font. Following the deprecation notice looks like the responsible move and silently breaks every custom font in the app. Register from a file URL instead.

## Applying changes

A brand can change while your app is open. `UIAppearance` is applied when a view enters a window and does not restyle views already on screen, so a mid-session swap gets you a half-updated app rather than an updated one. A fetched change is **held**:

```swift
try await brand.refresh()        // fetches, holds
await brand.pending != nil       // something is waiting

// on UIApplication.didBecomeActiveNotification:
await brand.activate()
```

Observers fire on activation, not arrival — nothing a caller can see changed when the payload landed. For an immediate swap, `refresh(activateNow: true)`.

The first payload always activates. "Do not restyle underneath someone" needs something to be styled first.

### Appearance

`assetURL(...)` uses the appearance of the payload that is **live**, not the one you asked for. Between asking for light and light arriving, those differ, and a light mark on a screen still painted dark is the exact failure the rule exists to prevent.

## Addresses

Every address is built from the grammar the surface publishes, and parameters go only where that grammar says they apply. A few refusals happen here rather than as a 400 you would see as a blank image view:

```swift
try brand.assetURL("logo-symbol", format: .svg, size: .px256)
// AddressError.sizeOnVector — an svg has no size to pick.
```

Sizes are a closed ladder, so `AssetSize` is an enum you cannot express a failing request with. `AssetSize.atLeast(200)` rounds up to the next rung, because a mark drawn larger and scaled down stays sharp. Composed destinations take neither size nor appearance: the destination decides both.

## Licence

Apache-2.0. Copyright 2026 Designless Private Limited. [designless.io](https://designless.io)
