#!/usr/bin/env bash
# IME-reset fence API — the winit-side compatibility patch.
#
# The Storytold apps moved to storytold egui 0.37, whose egui-winit expects two APIs from the
# storytold winit fork: the `WindowEvent::ImeResetCompleted { request_id }` variant and
# `Window::reset_ime()` / `Window::reset_ime_with_request()`. The builder replaces the fork
# patch with its own vendored winit, and when the app source ships its own `vendor/winit`
# snapshot (a stale provenance copy, as current PdfCraft stable does) only the Android backend
# directory is refreshed — so the copy being compiled still lacks the two APIs and every app
# fails with E0599 (`no variant named ImeResetCompleted`, `no method named
# reset_ime_with_request`).
#
# This script ports the two APIs the way the fork defines them (no-ops on Android) into
# whichever `vendor/winit` copy the build is about to compile. Every edit is guarded and
# idempotent: it applies only while the original text is still present, so it no-ops once
# upstream grows the API, and it is re-applied on a fresh checkout.
#
# Usage: winit_ime_fence.sh <source-dir> <app> <title>
set -euo pipefail

SRC="${1:?source dir}"
APP="${2:?app}"
TITLE="${3:?title}"

python3 - "$SRC" "$APP" "$TITLE" <<'PY'
from pathlib import Path
import sys

src, app, title = Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def fix(rel: str, old: str, new: str) -> bool:
    """Replace the single `old` in `rel` with `new`, unless already gone or already fixed."""
    path = src / rel
    try:
        text = path.read_text()
    except OSError:
        return False
    if old not in text or new in text or text.count(old) != 1:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


fixed = []

# 1. The ordered-cancellation-fence event, right after the IME event it belongs to.
if fix(
    "vendor/winit/src/event.rs",
    "    /// - **iOS / Android / Web / Orbital:** Unsupported.\n"
    "    Ime(Ime),\n"
    "\n"
    "    /// The cursor has moved on the window.\n",
    "    /// - **iOS / Android / Web / Orbital:** Unsupported.\n"
    "    Ime(Ime),\n"
    "\n"
    "    /// The ordered cancellation fence requested by [`Window::reset_ime_with_request`].\n"
    "    ///\n"
    "    /// Input already accepted before this reset is delivered before this event. New input\n"
    "    /// admitted after the reset follows it. This is a local input boundary, not an\n"
    "    /// acknowledgement from the input method or compositor. It is emitted even when no\n"
    "    /// preedit was visible, but not for unsupported, disallowed or failed resets.\n"
    "    ImeResetCompleted { request_id: u64 },\n"
    "\n"
    "    /// The cursor has moved on the window.\n",
):
    fixed.append("vendor/winit/src/event.rs (ImeResetCompleted fence event)")

# 2. The two reset entry points, after the IME-purpose setter they extend. The setter's
# body shape differs between snapshots (one line vs two), so the end of the function is
# located with a regex instead of a literal anchor.
import re as _re

_METHODS = (
    "\n"
    "    /// Discards the IME composition in progress and resets the input method's state.\n"
    "    ///\n"
    "    /// Has no effect while IME is not allowed.\n"
    "    ///\n"
    "    /// ## Platform-specific\n"
    "    ///\n"
    "    /// - **iOS / Android / Web / Orbital:** Unsupported.\n"
    "    ///\n"
    "    /// [`Ime::Preedit`]: crate::event::Ime::Preedit\n"
    "    /// [`Ime::Commit`]: crate::event::Ime::Commit\n"
    "    #[inline]\n"
    "    pub fn reset_ime(&self) {\n"
    "        let _span = tracing::debug_span!(\"winit::Window::reset_ime\").entered();\n"
    "        self.window.maybe_queue_on_main(|w| w.reset_ime())\n"
    "    }\n"
    "\n"
    "    /// Resets composition like [`Self::reset_ime`] and queues an ordered completion fence.\n"
    "    ///\n"
    "    /// A supported, allowed context that resets successfully receives\n"
    "    /// [`ImeResetCompleted`](crate::event::WindowEvent::ImeResetCompleted) with this\n"
    "    /// `request_id`, including when no preedit is visible. Unsupported platforms, an IME\n"
    "    /// that is not allowed, and native reset failures do not produce a successful completion.\n"
    "    #[inline]\n"
    "    pub fn reset_ime_with_request(&self, request_id: u64) {\n"
    "        let _span = tracing::debug_span!(\"winit::Window::reset_ime_with_request\").entered();\n"
    "        self.window.maybe_queue_on_main(move |w| w.reset_ime_with_request(request_id))\n"
    "    }\n"
)


def _fix_window() -> bool:
    path = src / "vendor/winit/src/window.rs"
    try:
        text = path.read_text()
    except OSError:
        return False
    if "reset_ime_with_request" in text:
        return False
    matches = list(
        _re.finditer(
            r"    pub fn set_ime_purpose\(&self, purpose: ImePurpose\) \{.*?\n    \}\n",
            text,
            _re.S,
        )
    )
    if len(matches) != 1 or "maybe_queue_on_main" not in matches[0].group(0):
        return False
    end = matches[0].end()
    path.write_text(text[:end] + _METHODS + text[end:])
    return True


if _fix_window():
    fixed.append("vendor/winit/src/window.rs (reset_ime/reset_ime_with_request)")

# 3. The Android no-ops, matching the fork (the platform never resets IME natively).
if fix(
    "vendor/winit/src/platform_impl/android/mod.rs",
    "    pub fn set_ime_purpose(&self, _purpose: ImePurpose) {}\n",
    "    pub fn set_ime_purpose(&self, _purpose: ImePurpose) {}\n"
    "\n"
    "    pub fn reset_ime(&self) {}\n"
    "\n"
    "    #[inline]\n"
    "    pub fn reset_ime_with_request(&self, _request_id: u64) {}\n",
):
    fixed.append("vendor/winit/src/platform_impl/android/mod.rs (Android reset no-ops)")

if fixed:
    print(f"  Added IME-reset fence APIs to {title}: {', '.join(fixed)}")
PY
