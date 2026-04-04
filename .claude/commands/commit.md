---
name: commit
description: Run checks, commit with AI message, and push
---

1. Run quality checks — fix ALL errors before continuing:
   ```bash
   swiftformat --lint --config .swiftformat tamagotchai/Sources
   swiftlint lint --config .swiftlint.yml --strict
   xcodebuild -project Tamagotchai.xcodeproj -scheme Tamagotchai -configuration Debug build
   ```

2. Review changes: `git status` and `git diff --staged` and `git diff`

3. Generate commit message:
   - Start with verb (Add/Update/Fix/Remove/Refactor)
   - Be specific and concise, one line preferred

4. Commit and push:
   ```bash
   git add -A
   git commit -m "your generated message"
   git push
   ```
