---
agent: vsd
description: "Show a concise help summary for VibeShield-Deploy: available commands, the 4-stage workflow, and how to get started."
---

The user is asking for help with VibeShield-Deploy. Do NOT start a deployment. Instead, print a concise help summary that covers:

1. **What VibeShield-Deploy does** — deploys applications to Azure using Azure DevOps 1ES pipelines, guiding the user through 4 stages.

2. **The 4 stages** — list them in a table:
   | Stage | Name | What Happens |
   |-------|------|-------------|
   | 1 | Readiness Check | Validates app type, Azure resources, DevOps setup, and scans for secrets |
   | 2 | Pipeline Setup | Generates a 1ES pipeline YAML and validates it |
   | 3 | Code Push | Pushes code to Azure DevOps and registers the pipeline |
   | 4 | Monitor & Verify | Polls the pipeline run and verifies the deployed app is live |

3. **How to start** — tell them to type `/vsd` for a one-shot deployment, or `/vsd Deploy my app to Azure` to start with a specific request.

4. **Common commands** — show a short table:
   | Command | What It Does |
   |---------|-------------|
   | `/vsd Deploy my app` | Full deployment (all 4 stages) |
   | `/vsd Check readiness` | Validate app, Azure account, and permissions (Stage 1 only) |
   | `/vsd Create pipeline` | Set up CI/CD pipeline (Stages 1-2, no push or deploy) |
   | `/vsd Monitor status` | Check a running pipeline |
   | `stop` | Pause the workflow |
   | `continue` | Resume after pausing |
   | `What does that mean?` | Get an explanation of the last step |

5. **Where to learn more** — point them to the full user guide: [VibeShield-Deploy User Guide](https://dev.azure.com/oneCELA/CELA_Demos_and_POCs/_git/VibeShield-Deploy?path=/docs/user-guide.md&_a=preview).
6. **Need more help?** — reach out to the CELA SPEAR team at [CELAVibeShieldSupport@microsoft.com](mailto:CELAVibeShieldSupport@microsoft.com) or join the [Office Hour](https://microsoft.sharepoint.com/teams/CELAEngineeringFundamentals/SitePages/Contact-Us.aspx).

Keep the response concise and scannable. Use tables and short sentences. Do not start any deployment stages.
