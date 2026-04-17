# Delta-Neutral Liquidity Vault: стратегия хеджирования Impermanent Loss для Uniswap V2

MVP-проект на Solidity `^0.8.20` и Foundry для протокола **Impermanent Loss Hedging Vault**.

## Что делает vault

Пользователь вносит в vault ETH и USDC. Контракт добавляет ликвидность в пул Uniswap V2 ETH/USDC, получает LP-токены и открывает хеджирующую позицию через Aave V3: берёт в долг WETH и продаёт его за USDC. Далее публичная функция `rebalance()` поддерживает дельта-нейтральность при изменении цены ETH.

Это MVP, а не production-ready система управления риском.  
В текущей версии **уже добавлены базовые контроли**:
- требования к риску долга (LTV/borrow cap/health factor);
- учёт накопления ставки долга (линейное начисление);
- проверка свежести оракула и circuit-breaker по отклонению oracle vs spot;
- ограничение размера свопа относительно резерва пула;
- модель капитала `LP asset - debt` через `getCapitalPosition1e18`.

Что всё ещё требует production-доработки:
- более точная модель процентов Aave (индексы и реалистичная плавающая ставка);
- более строгая модель execution cost (MEV, динамическое проскальзывание, multi-hop);
- полноценный риск-движок ликвидаций с on-chain проверкой параметров конкретного рынка Aave.

## Краткая теоретическая база

### 1. Стоимость LP-позиции Uniswap V2

Для 50/50 AMM с параметром ликвидности `L = sqrt(k)` и ценой ETH `P` стоимость позиции в ETH-эквиваленте:

$$
V(P) = 2L\sqrt{P}
$$

### 2. Дельта LP-позиции

Производная по цене даёт дельту:

$$
\Delta_{LP} = \frac{dV}{dP} = \frac{L}{\sqrt{P}}
$$

В терминах базового актива это эквивалентно количеству ETH, находящемуся в пуле на долю данного LP.

### 3. Цель хеджа

Чтобы компенсировать направленный риск позиции, vault открывает отрицательную дельту:

$$
\Delta_{hedge} = -\Delta_{LP}
$$

Практически это реализуется через заём WETH и продажу его за USDC.

### 4. Кривизна и остаточный PnL

LP-позиция имеет отрицательную гамму:

$$
\Gamma = \frac{d^2V}{dP^2} = -\frac{L}{2P^{3/2}}
$$

Из-за этого полностью “идеальный” хедж невозможен: остаётся остаточная кривизна, а также влияние комиссий и процента по займу.

### 5. Почему возникает impermanent loss

LP-позиция в constant product AMM ведёт себя как синтетическая продажа волатильности: при сильном движении цены пул автоматически ребалансирует состав активов, и стоимость LP начинает отставать от простой стратегии hold.

## Архитектура

- `ImpermanentLossHedgingVault.sol`
  - `deposit(uint256 amountETH, uint256 amountUSDC)`
  - `depositWithMin(uint256 amountETH, uint256 amountUSDC, uint256 minETH, uint256 minUSDC)`
  - `withdraw(uint256 lpAmount)`
  - `rebalance()`
  - `getCurrentDelta()`
  - `getImpermanentLoss()`
  - `getHealthFactorBps()`
  - `getCapitalPosition1e18()`
- Базовые примитивы безопасности OpenZeppelin:
  - `Ownable`
  - `Pausable`
  - `ReentrancyGuard`
  - `SafeERC20`
- Внешние интеграции:
  - интерфейсы Uniswap V2 router и pair
  - интерфейс Aave V3 pool
  - Chainlink ETH/USD oracle

## Как работает хедж

1. Vault добавляет ликвидность в Uniswap V2 и получает LP-токены.
2. Затем он оценивает текущую дельту позиции.
3. Если позиция слишком “лонговая” по ETH, vault занимает WETH в Aave.
4. Borrowed WETH продаётся за USDC, формируя short ETH exposure.
5. При изменении цены `rebalance()` сравнивает целевую и фактическую дельту и корректирует долг.

## Учёт проскальзывания и комиссий Uniswap (обновлено)

Коротко: **да, в MVP это учитывается на базовом уровне**.

- При свопах используется `getAmountsOut` + `amountOutMin` с `slippageBps`, то есть транзакция ограничивает худшее допустимое исполнение.
- Добавлен `depositWithMin(...)`, где вызывающий может передать собственные `minETH/minUSDC` для контроля входа в ликвидность.
- Добавлен лимит размера свопа (`maxSwapPortionBps`), чтобы не делать слишком большой impact в один шаг.
- Комиссия Uniswap (0.3% для V2) учитывается **неявно** через формулу пула и фактический `amountOut`.

Важно: отдельного бухгалтерского поля “накопленные DEX-комиссии/проскальзывание” в MVP пока нет — влияние отражается через фактический результат свопов и итоговую NAV.

## Безопасность

- `nonReentrant` защищает пользовательские state-changing функции.
- `whenNotPaused` блокирует `deposit` и `rebalance`; `withdraw` оставлен доступным для экстренного выхода.
- Валидация оракула включает stale-check и circuit-breaker по отклонению от spot-цены пула.
- Проскальзывание ограничивается через `slippageBps` и явные минимумы в `depositWithMin`.
- Есть лимиты риска долга: `maxLtvBps`, `liquidationThresholdBps`, `minHealthFactorBps`, `borrowCapWeth`.
- Есть линейное начисление процента долга (`variableBorrowRateBps`) для MVP-модели.

## Foundry

Проект уже содержит минимальные stub-реализации в `lib/`, поэтому он самодостаточен для MVP.

### Локальные тесты

```bash
forge test -vvv
```

В тестах добавлены:
- unit-тесты формул дельты/гаммы/impermanent loss;
- интеграционные сценарии ребалансировок и частичного вывода;
- security-кейсы (reentrancy, pause-поведение, borrow failure, slippage minimums);
- property-style проверки близости `delta` и `debt` после `rebalance`.

### Деплой в Sepolia

Перед запуском задайте переменные окружения:
- `PRIVATE_KEY`
- `ROUTER`
- `PAIR`
- `AAVE_POOL`
- `ETH_USD_ORACLE`
- `USDC`
- `WETH`
- `SEPOLIA_RPC_URL`

Команда деплоя:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast
```

## Литпейпер

### 1. Введение: что такое Impermanent Loss

Impermanent loss возникает, когда относительная цена активов в пуле меняется после внесения ликвидности. Для constant product AMM LP-позиция имеет вогнутый профиль выплат и проигрывает простой стратегии hold при направленном движении рынка.

### 2. Вывод дельты LP-токена

Для симметричного Uniswap V2 пула:

$$
V = 2L\sqrt{P}, \quad L = \sqrt{k}
$$

Тогда:

$$
\Delta_{LP} = \frac{dV}{dP} = \frac{L}{\sqrt{P}}
$$

Эта величина совпадает с количеством ETH, на которое экспонирована позиция.

### 3. Хеджирование через Aave

Чтобы нейтрализовать ETH-дельту LP, vault открывает короткую позицию по ETH через заём WETH на Aave V3 и продажу за USDC. При движении цены долг корректируется, чтобы short notional оставался близким к дельте LP.

### 4. Архитектура контракта и безопасность

MVP реализован как единый vault-контракт с входами:
- `deposit`
- `withdraw`
- `rebalance`

Меры защиты:
- `Ownable` для административных действий,
- `Pausable` для emergency stop,
- `ReentrancyGuard` для защиты от повторного входа,
- проверки свежести oracle и ограничение slippage.

### 5. Результаты симуляции

Тесты симулируют:
- добавление ликвидности,
- ребалансировку при росте и падении ETH,
- вывод средств после изменения цены.

Типичный результат:
- plain LP отстаёт от hold в направленном рынке,
- хедж уменьшает риск первой производной,
- остаточное отклонение связано с gamma, комиссиями и ставкой займа.

Сравнение можно строить по трём кривым:
- `hold value = initial ETH * current price + initial USDC`
- `LP value = value of the LP share`
- `hedged value = LP value + hedge PnL - fees`

Остаточный эффект соответствует кривизне:

$$
\frac{1}{2}\Gamma\sigma^2
$$

и является неизбежным для constant product AMM.

## Файлы

- `src/ImpermanentLossHedgingVault.sol`
- `src/mocks/*`
- `script/Deploy.s.sol`
- `test/Vault.t.sol`
- `foundry.toml`
