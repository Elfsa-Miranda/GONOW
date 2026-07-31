# Phase 0 change summary

Before this branch, a tracked client constant contained a model-provider credential, ordinary chat called the provider from Flutter, the three main AI/travel providers emitted free-form debug messages, there was no repository CI, and the production database schema/RLS/grant state could not be reproduced from the repository.

The local candidate now removes the credential, disables provider-direct calls, defines a fixed authenticated Release A gateway contract, introduces structured allowlisted logging, scans tracked/history/APK artifacts, and freezes a Flutter analyzer/test/build ratchet. Gateway tests pass 4/4, log-redaction tests pass 3/3, compatibility assertions pass 6/6, new analyzer errors are 0, and the debug APK builds successfully.

This is not a formal Release A acceptance. Provider revocation/billing evidence, the approved read-only production database inventory, the actual gateway server boundary, and independent owner decisions remain pending. No production write, push, merge, deployment, or client traffic switch occurred.
