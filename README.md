# KipuBankV2

Vault multi-token (ETH + ERC-20) con **cap global en USD (6 decimales, estilo USDC)** usando **Chainlink Data Feeds**, control de acceso con **AccessControl** y protección `nonReentrant`.

> **Dirección (Sepolia):** `0x8552B57E9eeD229c190eF427Ff369b4EE3e7ed06`
> **Etherscan (verificado):** [https://sepolia.etherscan.io/address/0x8552B57E9eeD229c190eF427Ff369b4EE3e7ed06#code](https://sepolia.etherscan.io/address/0x8552B57E9eeD229c190eF427Ff369b4EE3e7ed06#code)

---

## Índice

* [Cómo funciona (USD6)](#cómo-funciona-usd6)
* [Mejoras vs V1](#mejoras-vs-v1)
* [Parámetros de despliegue](#parámetros-de-despliegue)
* [Despliegue (Remix + Sepolia)](#despliegue-remix--sepolia)
* [Configuración de oráculos](#configuración-de-oráculos)
* [Roles y pausa](#roles-y-pausa)
* [Interacción (ETH)](#interacción-eth)
* [Interacción (ERC-20)](#interacción-erc-20)
* [Errores frecuentes](#errores-frecuentes)
* [Transacciones de ejemplo](#transacciones-de-ejemplo)
* [Decisiones y trade-offs](#decisiones-y-trade-offs)
* [Limitaciones conocidas](#limitaciones-conocidas)
* [Notas de desarrollo](#notas-de-desarrollo)
* [Licencia](#licencia)

---

## Cómo funciona (USD6)

El contrato mantiene **contabilidad interna en USD con 6 decimales (USD6)**, similar a USDC.
Cada depósito/retiro se convierte a USD6 usando el `price` del feed (`token/USD`).

**Fórmula (ETH como ejemplo):**

```text
usd6 = amountWei * price * 1e6 / 10^(tokenDecimals + priceDecimals)
```

* Para ETH: `tokenDecimals = 18`, `priceDecimals` suele ser `8` en Chainlink.
* Ej.: si depositás `0.001 ETH` y `ETH ≈ 3,300 USD`, entonces `usd6 ≈ 3_300_000` (3.3 USD).

El **cap global** y el **límite por retiro** se expresan también en USD6:

* 10 USD → `10_000_000`
* 50 USD → `50_000_000`
* 100 USD → `100_000_000`

---

## Mejoras vs V1

* **Multi-token:** ETH se representa como `address(0)`; ERC-20 vía `depositERC20/withdrawERC20`.
* **Contabilidad en USD6** e **inmutables** de cap y límite por retiro.
* **Oráculos Chainlink** por token (`token/USD`).
* **Roles (AccessControl):** `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` + `pause()`.
* **Seguridad:** patrón **CEI** (Checks–Effects–Interactions), `nonReentrant`, errores personalizados, mappings anidados.
* **NatSpec** en eventos, errores, modificadores y funciones `view`.

---

## Parámetros de despliegue

> Recomendación para test:

* `bankCapUsd6`: `100000000`  (100 USD)
* `withdrawLimitUsd6`: `10000000` (10 USD) — ó `0` para desactivar límite
* `admin`: `<0xTU_ADMIN>`

> **Recordatorio:** USD6 = USD × 1e6.
> Ej.: 5 USD = `5_000_000`, 50 USD = `50_000_000`, 100 USD = `100_000_000`.

---

## Despliegue (Remix + Sepolia)

1. **Environment:** `Injected Provider – MetaMask (Sepolia)`.
2. **Deploy** con los parámetros anteriores.
3. **Verify & Publish** en Etherscan usando **Standard JSON Input** (desde Remix → *Compilation Details* → *Download*).

---

## Configuración de oráculos

Tras el deploy, mapeá cada token a su feed `token/USD`.

* **ETH/USD (Sepolia):** `0x694AA1769357215DE4FAC081bf1f309aDC325306`

```solidity
// ETH = address(0)
setFeed(address(0), 0x694AA1769357215DE4FAC081bf1f309aDC325306);
```

* **ERC-20 (opcional):**
  `setFeed(<TOKEN>, <AGG_TOKEN_USD>)`
  *(Si el token no tiene feed en Sepolia, ese token no puede usarse.)*

> Verificaciones rápidas (lecturas):
>
> * `s_feed(address(0))` → debe devolver la dirección del feed de ETH.
> * `s_paused()` → debe ser `false`.
> * `totals()` → `(totalUsd6, capUsd6, withdrawLimitUsd6)`.

---

## Roles y pausa

* **Otorgar rol:** `grantRole(PAUSER_ROLE, <addr>)`
* **Comprobar:** `hasRole(PAUSER_ROLE, <addr>)`
* **Pausar/Reanudar:** `pause(true/false)`
* **Revocar/renunciar:** `revokeRole(...)`, `renounceRole(...)`
* **Admin de un rol:** `getRoleAdmin(PAUSER_ROLE)` (por defecto `DEFAULT_ADMIN_ROLE`)

---

## Interacción (ETH)

* **Depositar:**
  `depositETH(amount)` con:

  * `amount` **en wei** (0.001 ETH = `1000000000000000`)
  * **VALUE = mismo ETH** (0.001 en el selector de Ether)
* **Retirar:**
  `withdrawETH(amount)` → `amount` en wei, **≤ balance** y **≤ `withdrawLimitUsd6`** (si está activo).
* **Lecturas útiles:**

  * `balanceOf(address(0), 0xTU_ADDR)` → balance en wei
  * `totals()` → `(totalUsd6, capUsd6, withdrawLimitUsd6)`

> Si MetaMask dice “simulation failed”, suele ser: `Paused`, `CapExceeded`, `WithdrawAboveLimit`, `FeedNotConfigured` o `NativeMismatch` (VALUE ≠ amount).

---

## Interacción (ERC-20)

1. En el contrato del token: `approve(<KIPUBANKV2>, <amount>)`.
2. `depositERC20(<TOKEN>, <amount>)`.
3. `withdrawERC20(<TOKEN>, <amount>)` (sujeto al límite en USD6 si está activo).
4. `balanceOf(<TOKEN>, 0xTU_ADDR)` para ver tu saldo interno de ese token.

---

## Errores frecuentes

* `NativeMismatch()` → En `depositETH`, **VALUE** debe ser igual a `amount`.
* `ZeroAmount()` → `amount == 0`.
* `FeedNotConfigured(token)` → Falta `setFeed(token, aggregator)`.
* `Paused()` → `pause(true)`, reintentar con `pause(false)`.
* `CapExceeded()` → El depósito en USD6 supera `bankCapUsd6`.
* `WithdrawAboveLimit()` → El retiro en USD6 supera `withdrawLimitUsd6`.
* `InsufficientBalance(requested, available)` → Intentás retirar más de tu saldo.

---

## Transacciones de ejemplo

* **Depósito (Sepolia):**
  [https://sepolia.etherscan.io/tx/0x64c37f2d125af7e110b6c52b3b6c4fada577254c4c7a97f404bdb72b09d7e6f9](https://sepolia.etherscan.io/tx/0x64c37f2d125af7e110b6c52b3b6c4fada577254c4c7a97f404bdb72b09d7e6f9)
* **Retiro (Sepolia):**
  [https://sepolia.etherscan.io/tx/0xfb1a1d97433675c9469c541e03c868f6dfe8179023c3b066ff3b35e578a425da](https://sepolia.etherscan.io/tx/0xfb1a1d97433675c9469c541e03c868f6dfe8179023c3b066ff3b35e578a425da)

---

## Decisiones y trade-offs

* **USD6** simplifica reportes y límites, pero depende de **oráculos** (Chainlink) y de que exista feed para el token.
* `nonReentrant` + **CEI** en rutas críticas para robustez.
* `receive/fallback` revertidos → fuerza uso de `deposit` y mantiene consistencia contable.
* `unchecked` solo donde está probado que no hay overflow; contadores con aritmética chequeada.

---

## Limitaciones conocidas

* Solo son utilizables tokens con feed `token/USD` disponible en la red.
* `bankCapUsd6` y `withdrawLimitUsd6` son **inmutables** (se cambian con redeploy).
* El valor en USD depende del precio vigente del feed (puede haber leve retraso).

---

## Notas de desarrollo

* **Solidity:** `^0.8.x`
* **Compilador/Optimizer:** igual al usado al **Verify & Publish** (Standard JSON Input).
* **Framework:** Remix (deploy) + Chainlink Data Feeds.

---

## Licencia

**MIT** — ver archivo `LICENSE`.

---

¿Querés que además te lo deje en inglés para el perfil global o preferís solo español?
