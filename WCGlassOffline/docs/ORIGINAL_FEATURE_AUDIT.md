# WCGlass 4.1.6-2 — Static Feature Audit

This document records a static inspection of the user-provided Debian package. It is a feature inventory and independent-reimplementation plan, not a decompilation or a claim that every symbol is an active feature.

## Package facts
- Package: `com.wechat.liquidglass`
- Version: `4.1.6-2`
- Architecture: `iphoneos-arm64` (universal arm64 + arm64e Mach-O)
- Dependency declared by original package: `mobilesubstrate`
- Injection filter: `com.tencent.xin`
- Main payload: `WCGlass.dylib` (61,706,592 bytes)
- Filter plist: `WCGlass.plist`

## Feature families identified from embedded class and preference-key names

### Liquid Glass / system surfaces
- Glass material, blur, tint, opacity, gradients, borders, shadows, edge glow and corner shaping.
- Bar layout, safe-area extension, material fallback, masking and animated gradient controls.
- Smooth-corner and content-corner configuration.

### Morphing navigation and tab bar
- Morphing tab bar, custom and vertical tab layouts, tab item visuals and badges.
- Expanding glass, frosted lens, glass containers, clear/soft glass modes.
- Tab icon shape, title placement, selection, extra actions and search controls.
- Animated beam/highlight overlays and morphing action menus.

### Home chat grouping / fold sidebar
- Home chat groups, group membership, filtering of chatrooms/contacts/pinned chats.
- Expand/collapse behavior, accordion and strip presentation, unread badges.
- Sidebar position, width, icons, names, spacing and visibility.
- Full-screen group navigation and swipe interactions.

### Chat screen
- Chat top capsules, avatar controls, title/subtitle and morphing actions.
- Chat input glass, bottom bar modes, gradient and border settings.
- Bubble glass, gradients, compact layout, quote styling and text colors.
- Avatar size/corners, chat indentation, page width and related layout controls.

### Settings and customization
- Many preference keys indicate light/dark color variants, geometry, animation, typography and per-feature toggles.
- A settings UI appears to expose dedicated tab-bar and home-group configuration sections.

## Important boundary
The binary contains explicit authorization-related symbols and server-auth state keys. This project will not patch, suppress, forge, or bypass that authorization mechanism, nor reuse proprietary implementation code/assets. The independent project can reproduce user-facing features from scratch where lawful and technically feasible, and operate offline without contacting the original service.

## Reimplementation plan

1. **Feature specification:** map visible settings and behavior to an independent specification. Static symbol names alone are insufficient; compare against user-provided screenshots or descriptions.
2. **Glass rendering core:** build a reusable UIKit rendering layer (material, tint, highlight, border, shadow, corner treatment) with safe lifecycle handling.
3. **Morphing tab bar:** independent view hierarchy, layout, selection transitions, badges and accessibility.
4. **Home group UI:** local-only group model and persistence, then integrate with verified WeChat list APIs/UI hooks. Do not alter WeChat messages or account data.
5. **Chat surfaces:** input area and bubble presentation, gated by compatibility checks.
6. **Settings UI:** local preferences, reset/export/import, and clear compatibility status.
7. **Device validation:** test on the stated Rootless iOS 15–16 environment, with crash-safe disable switch and rollback instructions.

## Current prototype status
The existing `WCGlassOffline/` directory is only an initial proof-of-concept. It is not a port of WCGlass 4.1.6-2 and must not be described as feature-complete. The next implementation work should replace the generic navigation/tab hooks with the independent rendering core and a dedicated morphing tab-bar implementation.
