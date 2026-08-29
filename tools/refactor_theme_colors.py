#!/usr/bin/env python3
"""One-off: migrate TalkFreeColors -> AppTheme / Theme.of(context). Run from repo root."""
import os
import re

FILES = [
    "lib/screens/onboarding_screen.dart",
    "lib/screens/number_selection_screen.dart",
    "lib/screens/choose_plan_screen.dart",
    "lib/widgets/premium_backdrop.dart",
    "lib/widgets/talkfree_logo.dart",
    "lib/screens/virtual_number_screen.dart",
    "lib/screens/inbox_screen.dart",
    "lib/screens/subscription_screen.dart",
    "lib/screens/sms_test_screen.dart",
    "lib/widgets/pick_available_number_sheet.dart",
    "lib/screens/virtual_number_claim_flow.dart",
    "lib/screens/settings_screen.dart",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def process(path: str) -> None:
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        print("skip", path)
        return
    with open(full, encoding="utf-8") as f:
        s = f.read()
    s = re.sub(
        r"import\s+['\"].*talkfree_colors\.dart['\"];\s*\n",
        "",
        s,
    )
    s = s.replace("TalkFreeColors.beigeGold", "AppTheme.neonGreen")
    s = s.replace("TalkFreeColors.primary", "AppTheme.neonGreen")
    s = s.replace("TalkFreeColors.offWhite", "Theme.of(context).colorScheme.onSurface")
    s = s.replace("TalkFreeColors.mutedWhite", "Theme.of(context).colorScheme.onSurfaceVariant")
    s = s.replace(
        "TalkFreeColors.cardBg",
        "(Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface)",
    )
    s = s.replace("TalkFreeColors.backgroundTop", "AppTheme.darkBg")
    s = s.replace("TalkFreeColors.backgroundBottom", "AppColors.darkBackgroundDeep")
    s = s.replace("TalkFreeColors.backgroundMid", "AppColors.surfaceDark")
    s = s.replace("TalkFreeColors.charcoal", "AppColors.surfaceDark")
    s = s.replace("TalkFreeColors.deepBlack", "AppTheme.darkBg")
    s = s.replace("TalkFreeColors.onPrimary", "Theme.of(context).colorScheme.onPrimary")
    if "app_theme.dart" not in s and path.endswith(".dart"):
        lines = s.splitlines(keepends=True)
        inserted = False
        for i, line in enumerate(lines):
            if "app_colors.dart" in line:
                lines.insert(i + 1, "import '../theme/app_theme.dart';\n")
                inserted = True
                break
        if not inserted:
            for i, line in enumerate(lines):
                if line.startswith("import 'package:flutter/material.dart'"):
                    lines.insert(i + 1, "import '../theme/app_theme.dart';\n")
                    break
        s = "".join(lines)
    with open(full, "w", encoding="utf-8") as f:
        f.write(s)
    print("ok", path)


if __name__ == "__main__":
    for p in FILES:
        process(p)
