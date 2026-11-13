// Deployed addresses and chain settings for the order page (testnets only). Addresses are the
// live deployment recorded in docs/tx-hashes.md.

export const ORIGIN = {
  id: 1301,
  name: 'Unichain Sepolia',
  rpc: 'https://sepolia.unichain.org',
  explorer: 'https://sepolia.uniscan.xyz',
};

export const REACTIVE = {
  id: 5318007,
  name: 'Reactive Lasna',
  rpc: 'https://lasna-rpc.rnk.dev/',
  explorer: 'https://lasna.reactscan.net',
};

export const ADDR = {
  vault: '0x6a8932797F1FB9D164F6e075Cb4F525FEb824184',
  reactive: '0xc358fFaA2bCc6bE005Ab4063Fb7dfcc2Ef4f56fe',
  swapper: '0x715666dc26bB46dBADA0112E0c9E6f7Db945EDAa',
  token0: '0x0A75150631C8E1ad3FcB48D8B0478B1DC685CD2b',
  token1: '0x354Fc758Ac107D77FF53d3e0b0B2BAE1C55d58EC',
};

/** The pool the vault serves: fee 0.3%, tick spacing 60, no hooks. */
export const POOL_KEY = {
  currency0: ADDR.token0,
  currency1: ADDR.token1,
  fee: 3000,
  tickSpacing: 60,
  hooks: '0x0000000000000000000000000000000000000000',
};

/** How many of the newest order ids "My orders" reads. */
export const ORDER_SCAN = 50;
/** How long the timeline waits for the loop after a demo swap, in milliseconds. */
export const WATCH_MS = 90_000;
export const POLL_MS = 1_000;

export const VAULT_ABI = [
  {
    type: 'function', name: 'createOrder', stateMutability: 'nonpayable',
    inputs: [{
      name: 'p_', type: 'tuple', components: [
        { name: 'zeroForOne', type: 'bool' },
        { name: 'amountIn', type: 'uint128' },
        { name: 'useStop', type: 'bool' },
        { name: 'stopTick', type: 'int24' },
        { name: 'useTakeProfit', type: 'bool' },
        { name: 'takeProfitTick', type: 'int24' },
        { name: 'trailingDistance', type: 'uint24' },
        { name: 'minAmountOut', type: 'uint128' },
        { name: 'maxSlippageBps', type: 'uint16' },
        { name: 'expiry', type: 'uint64' },
      ],
    }],
    outputs: [{ name: 'id', type: 'uint256' }],
  },
  { type: 'function', name: 'cancelOrder', stateMutability: 'nonpayable', inputs: [{ name: 'id_', type: 'uint256' }], outputs: [] },
  {
    type: 'function', name: 'getOrder', stateMutability: 'view', inputs: [{ name: 'id_', type: 'uint256' }],
    outputs: [{
      name: '', type: 'tuple', components: [
        { name: 'owner', type: 'address' },
        { name: 'expiry', type: 'uint64' },
        { name: 'status', type: 'uint8' },
        { name: 'zeroForOne', type: 'bool' },
        { name: 'useStop', type: 'bool' },
        { name: 'useTakeProfit', type: 'bool' },
        { name: 'nStop', type: 'int24' },
        { name: 'nTakeProfit', type: 'int24' },
        { name: 'nAtCreation', type: 'int24' },
        { name: 'trailingDistance', type: 'uint24' },
        { name: 'maxSlippageBps', type: 'uint16' },
        { name: 'amountIn', type: 'uint128' },
        { name: 'minAmountOut', type: 'uint128' },
      ],
    }],
  },
  { type: 'function', name: 'normalizedTick', stateMutability: 'view', inputs: [{ name: 'zeroForOne_', type: 'bool' }], outputs: [{ name: '', type: 'int24' }] },
  { type: 'function', name: 'nextOrderId', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: 'uint256' }] },
  { type: 'function', name: 'activeOrdersOf', stateMutability: 'view', inputs: [{ name: 'owner', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] },
  {
    type: 'event', name: 'OrderCreated', inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
      { name: 'zeroForOne', type: 'bool', indexed: false },
      { name: 'amountIn', type: 'uint128', indexed: false },
      { name: 'useStop', type: 'bool', indexed: false },
      { name: 'nStop', type: 'int24', indexed: false },
      { name: 'useTakeProfit', type: 'bool', indexed: false },
      { name: 'nTakeProfit', type: 'int24', indexed: false },
      { name: 'trailingDistance', type: 'uint24', indexed: false },
      { name: 'expiry', type: 'uint64', indexed: false },
      { name: 'nAtCreation', type: 'int24', indexed: false },
    ],
  },
  {
    type: 'event', name: 'OrderExecuted', inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'side', type: 'uint8', indexed: false },
      { name: 'amountOut', type: 'uint256', indexed: false },
      { name: 'nTick', type: 'int24', indexed: false },
      { name: 'executedAt', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event', name: 'OrderExecutionFailed', inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'side', type: 'uint8', indexed: false },
      { name: 'reason', type: 'bytes', indexed: false },
    ],
  },
  // Errors, so failed simulations explain themselves.
  ...['HooksNotSupported', 'PoolNotInitialized', 'NotOwner', 'ExpiryTooFar', 'TooManyOrdersForOwner', 'ZeroAmount',
    'ExpiryInPast', 'NoTrigger', 'SlippageTooHigh', 'TrailingDistanceTooLarge', 'TickOutOfRange', 'TooManyActiveOrders',
    'TokenTransferFailed', 'NotOrderOwner', 'OrderNotActive', 'NotExpired', 'Reentrancy']
    .map((name) => ({ type: 'error', name, inputs: [] })),
  { type: 'error', name: 'StopNotBelowPrice', inputs: [{ name: 'nStop', type: 'int24' }, { name: 'nNow', type: 'int24' }] },
  { type: 'error', name: 'TakeProfitNotAbovePrice', inputs: [{ name: 'nTakeProfit', type: 'int24' }, { name: 'nNow', type: 'int24' }] },
  { type: 'error', name: 'IncompleteDeposit', inputs: [{ name: 'received', type: 'uint256' }, { name: 'expected', type: 'uint256' }] },
  ...TOKEN_ERRORS(),
];

/** The test tokens' errors, which surface through the vault's and the swapper's calls. */
function TOKEN_ERRORS() {
  return [
    { type: 'error', name: 'InsufficientBalance', inputs: [{ name: 'balance', type: 'uint256' }, { name: 'needed', type: 'uint256' }] },
    { type: 'error', name: 'InsufficientAllowance', inputs: [{ name: 'allowance', type: 'uint256' }, { name: 'needed', type: 'uint256' }] },
  ];
}

export const REACTIVE_ABI = [
  {
    type: 'function', name: 'getTracked', stateMutability: 'view', inputs: [{ name: 'id_', type: 'uint256' }],
    outputs: [{
      name: '', type: 'tuple', components: [
        { name: 'active', type: 'bool' },
        { name: 'zeroForOne', type: 'bool' },
        { name: 'useStop', type: 'bool' },
        { name: 'useTakeProfit', type: 'bool' },
        { name: 'nStop', type: 'int24' },
        { name: 'nTakeProfit', type: 'int24' },
        { name: 'nPeak', type: 'int24' },
        { name: 'trailingDistance', type: 'uint24' },
        { name: 'expiry', type: 'uint64' },
        { name: 'notBefore', type: 'uint64' },
        { name: 'windowStart', type: 'uint64' },
        { name: 'attempts', type: 'uint8' },
        { name: 'createdPos', type: 'uint128' },
        { name: 'lastFailedPos', type: 'uint128' },
      ],
    }],
  },
  {
    type: 'event', name: 'Triggered', inputs: [
      { name: 'id', type: 'uint256', indexed: true },
      { name: 'side', type: 'uint8', indexed: false },
      { name: 'nTick', type: 'int24', indexed: false },
      { name: 'nThreshold', type: 'int24', indexed: false },
    ],
  },
];

export const SWAPPER_ABI = [
  {
    type: 'function', name: 'swapExactIn', stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'key_', type: 'tuple', components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'zeroForOne_', type: 'bool' },
      { name: 'amountIn_', type: 'uint256' },
      { name: 'minAmountOut_', type: 'uint256' },
      { name: 'recipient_', type: 'address' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  { type: 'error', name: 'ZeroAmount', inputs: [] },
  { type: 'error', name: 'AmountTooLarge', inputs: [] },
  { type: 'error', name: 'ZeroRecipient', inputs: [] },
  { type: 'error', name: 'InsufficientOutput', inputs: [{ name: 'amountOut', type: 'uint256' }, { name: 'minAmountOut', type: 'uint256' }] },
  { type: 'error', name: 'PartialFill', inputs: [{ name: 'amountInUsed', type: 'uint256' }, { name: 'amountIn', type: 'uint256' }] },
  { type: 'error', name: 'UnexpectedDelta', inputs: [{ name: 'inDelta', type: 'int128' }, { name: 'outDelta', type: 'int128' }] },
  ...TOKEN_ERRORS(),
];

export const ERC20_ABI = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ name: 'o', type: 'address' }, { name: 's', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ name: 's', type: 'address' }, { name: 'v', type: 'uint256' }], outputs: [{ name: '', type: 'bool' }] },
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: 'string' }] },
  // The demo tokens are faucet tokens: anyone may mint (src/v4/TestToken.sol).
  { type: 'function', name: 'mint', stateMutability: 'nonpayable', inputs: [{ name: 'to_', type: 'address' }, { name: 'amount_', type: 'uint256' }], outputs: [] },
];

/** How many of each test token "Get test tokens" mints: enough for several orders and pushes. */
export const FAUCET_AMOUNT = 2_000n * 10n ** 18n;
