# Security

## Report a vulnerability

**Never report a vulnerability in a public issue**, pull request or discussion, and never post a proof of concept in public.

**Report privately** through GitHub's private vulnerability reporting: [Report a vulnerability](https://github.com/DebenLabs/gage-contracts/security/advisories/new), in gage's public contracts repository. Only gage sees it.

gage runs a bug bounty: up to **$5,000 for a Critical** smart-contract vulnerability that can cause loss of user funds. High, Medium and Low reports are rewarded too. Severity follows Immunefi's classification. To claim a reward, follow the bounty's rules: it takes reports through its own form, [gage.cash/bugbounty/report](https://gage.cash/bugbounty/report).

- Policy, rules and rewards: [docs.gage.cash/protocol/bug-bounty](https://docs.gage.cash/protocol/bug-bounty)
- The published scope, every contract in it: [docs.gage.cash/protocol/bounty-targets](https://docs.gage.cash/protocol/bounty-targets), and as JSON: [gage.cash/bounty-scope.json](https://gage.cash/bounty-scope.json)
- The live deployment manifest: [gage.cash/api/deployment](https://gage.cash/api/deployment)

Test on a fork of Robinhood Chain mainnet (chain ID 4663), never against live funds.

## Audits

- [Pashov Audit Group](https://www.pashov.com) reviewed the partner-lending contracts and the loan engine they lend through, 28 September to 12 October 2026. The report and the code it reviewed: [DebenLabs/gage-audit](https://github.com/DebenLabs/gage-audit).
- The rehypo source and the lender-AMM kit are not audited. The kit builds on OpenZeppelin uniswap-hooks v1.3.0-rc.0, a release candidate with no published audit. A partner audits its own deployment.

Source verification is not an audit. It shows that the source here builds the deployed bytecode.
