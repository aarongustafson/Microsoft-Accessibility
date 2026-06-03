---
agent: vsd
description: "Post-deployment guidance for users after a successful Azure deployment. Covers app verification, Application Insights, code update workflow, troubleshooting, and cleanup. Loaded by orchestrator and vsd after Stage 4 succeeds."
---

# Post-Deployment Guide

After a successful deployment, provide the user with actionable next steps organized by priority.

## Immediate (Do Now)

| Action | Why | How |
|--------|-----|-----|
| **Bookmark your app URL** | So you can check your app anytime | Your app is live at the URL shown in the deployment summary |
| **Bookmark your pipeline** | So you can check build status | The pipeline URL was shown in the deployment summary — save it for quick access |
| **Verify the app works** | Confirm everything looks right | Open the app URL in your browser and test the main features |

## Recommended (Within a Week)

| Action | Why | How |
|--------|-----|-----|
| **Set up Application Insights** | See how your app is performing, track errors, and understand usage | Say *"Set up Application Insights for monitoring"* |
| **Add a custom domain** | Replace the default Azure URL with your own domain (e.g., `myapp.contoso.com`) | Say *"Add a custom domain to my app"* |
| **Review pipeline alerts** | Get notified when builds fail | In Azure DevOps, go to your pipeline → click the bell icon → set up notifications |

## How to Update Your App

When you make changes to your code, the pipeline will automatically rebuild and redeploy:

1. **Edit your code** in VS Code
2. **Save your files**
3. **Push your changes** — say *"Push my code"* or run `git add -A && git commit -m "your message" && git push`
4. **The pipeline runs automatically** — it detects the new code and rebuilds/redeploys
5. **Wait ~5-10 minutes** for the build and deployment to complete
6. **Check your app** — refresh the URL to see your changes

> 💡 You don't need to re-run the deployment workflow. Once the pipeline is set up, it handles everything automatically on each push.

## What If Something Breaks?

| Situation | What to Do |
|-----------|-----------|
| App shows an error after an update | Check the pipeline — if the build failed, fix the code error and push again. Say *"Check my pipeline status"* |
| App is down or not responding | Say *"Diagnose my deployment"* or check App Insights for error details |
| Need to go back to a previous version | V1 does not support automatic rollback. Push a fix or revert the code change: `git revert HEAD && git push` |
| Pipeline keeps failing | Say *"Help me fix my pipeline"* — the diagnostics will identify the issue |

## Cleanup (Optional)

If you want to remove everything that was set up:

> ⚠️ **Cleanup deletes your deployed app and pipeline.** This cannot be undone.

Contact the **AI4CELA SPEAR team** to:
- Delete the project resource group (removes all Azure resources)
- Remove the pipeline from Azure DevOps, if desired

The management resource group (`rg-vibe-<username>`) and service connection are shared across projects — do NOT delete them unless you're removing all VibeShield-Deploy projects.
