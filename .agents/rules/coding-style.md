---
trigger: always_on
---

## CODING STYLE

1. **No Hardcoded Values**: Dimensional params, timeouts, design tokens, and limits must derive from centralized constants. For digital signal processing, avoid using magical numbers or constants if it is a mathematical operation. Instead, use mathematical operations or formulas to derive the values. If needed, define the constants in the codebase and add a comment explaining the purpose of the constant.
2. **Fail-Closed, Zero Blind Fallbacks**: Fallback logic hides failures and unpredictably loads systems. Missing metadata, unresolvable routes, and I/O failures must reject loudly with error codes.

## CODE QUALITY

1. Stubbed code, `//TODO`, pseudocode and dead code are forbidden in the codebase.