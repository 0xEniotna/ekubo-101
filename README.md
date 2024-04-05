# Demistify Ekubo

Ekubo is an insane AMM deployed on Starknet. It uses a concentrated liquidity mecanism (CLMM) aka Uniswap v3 instead of the old and unefficient CFMM.
It is developped by Moody Salem, an old Uniswap dev who helped to create the Uniswap v3 [whitepaper](https://uniswap.org/whitepaper-v3.pdf).
More about Ekubo [here](https://docs.ekubo.org/).

# How does Ekubo work

Ekubo uses an "ask permission-callback" system (it is probably not the official way of describing it but this is how I understand it).
For instance if you wanted to make a swap, you would have to implement 2 different functions. The first one would be called by the user and the second by Ekubo core contract. You make a call towards the core, which will trigger a callback function that will come back to your contract calling a specific function named `locked`.
You must implement all the logic within the `locked` function.

For isntance, in my `router.cairo` file, the function `swap` calls this:

```rs
call_core_with_callback::<
    CallbackData, Array<Array<Delta>>
>(self.core.read(), @CallbackData::SwapCallback(swaps))
```

I didn't invent that one, it is a copy pasta (almost) of [this](https://github.com/EkuboProtocol/abis/blob/main/src/router_lite.cairo).
The signature of that function is:

```rs
pub fn call_core_with_callback<TInput, TOutput, +Serde<TInput>, +Serde<TOutput>>(
    core: ICoreDispatcher, input: @TInput
) -> TOutput ;
```

It takes 2 params, the core contract dispatcher and whatever input (could be the swap data, the withdraw data, the add liquidity data...).
The output can be whatever suits your project the most. In my example, the return output is an array of `Deltas` which is a representation of a trade/change in balance.

What happens next is the core contract doing a callback towards my own contract expecting to call `locked`.
My `locked` function looks like this:

```rs
fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
    let core = self.core.read();
    // Called by the core contract
    match consume_callback_data::<CallbackData>(core, data) {
        CallbackData::SwapCallback(params) => {
            let mut swaps = params;
            swap_inner(swaps, core)
        },
        CallbackData::MintPositionCallback(params) => {
            let position_contract = self.position.read();
            mint_inner(params, core, position_contract)
        },
        CallbackData::AddLiquiditiyCallback(params) => {
            let position_contract = self.position.read();
            add_inner(params, core, position_contract)
        },
        CallbackData::WithdrawLiquidityCallback(params) => {
            let position_contract = self.position.read();
            withdraw_inner(params, core, position_contract)
        }
    }
}
```

I've implement different scenarios. In the context of a swap, only this part is interesting:

```rs
match consume_callback_data::<CallbackData>(core, data) {
    CallbackData::SwapCallback(params) => {
        let mut swaps = params;
        swap_inner(swaps, core)
    },
```

My `locked` function accepts/consumes the callback from the core by calling `consume_callback_data::<CallbackData>(core, data)`. `CallbackData` is a custom enum. It is the input type of my call.
To clean my code and to avoid having a 1000 lines `locked` function, I implement the logic in other functions. `swap_inner` implements the swap logic. Basically, it loops through all swaps and executes them one by one. The most important line in `swap_inner` is:

```rs
let delta = core.swap(
    node.pool_key,
    SwapParameters {
        amount: token_amount.amount,
        is_token1: is_token1,
        sqrt_ratio_limit: node.sqrt_ratio_limit,
        skip_ahead: node.skip_ahead,
    }
);
```

Type `RouteNode` is:

```rs
pub struct RouteNode {
    pub pool_key: PoolKey,
    pub sqrt_ratio_limit: u256,
    pub skip_ahead: u128,
}
```

and type `PoolKey` is:

```rs
pub struct PoolKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee: u128,
    pub tick_spacing: u128,
    pub extension: ContractAddress,
}
```

And now, it's becoming a bit more difficult to understand. How the fuck are we supposed to fill the params ?

- `token0`, `token1` is ok. token1 > token0.
- `extension` is most often 0. Ekubo enables third parties to implement pool extensions to add new features.
- `fee`is the pool fee. If it's straighforward to understand what it is, its computation is trickier. The doc says: `Fee is a 0.128 fixed point number, so to compute the fee, we can do floor(0.05% * 2**128)`. For a fixed point arithmetic intro, [this paper](https://inst.eecs.berkeley.edu/~cs61c/sp06/handout/fixedpt.html) gives a good overview.
  To compute the fee, we will need a little python program (I stole it from @enitrat):

```python
# Compute the fee value for a pool
fee_0_3 = 0.3/100
fee = math.floor(fee_0_3 * 2**128)
print(hex(fee))
```

which gives us this:

```python
0.01%
0x68db8bac710cb4000000000000000
0.05%
0x20c49ba5e353f80000000000000000
0.3%
0xc49ba5e353f7d00000000000000000
1%
0x28f5c28f5c28f600000000000000000
5%
0xccccccccccccd000000000000000000
```

- `tick_spacing`. From the doc: `The tick spacing of 0.1% is represented as an exponent of 1.000001, so it can be computed as log base 1.000001 of 1.001, which is roughly equal to 1000.`. A price range is split in a lot of small units called ticks. The smallest the tick, the more precise the price can be.
  With a python snippet:

```python
# Compute tick spacing value
tick_spacing_percent = 0.1/100
tick_spacing = int(math.log(1 + tick_spacing_percent, 1.000001))
print(tick_spacing)
```

The tick precision can be found when you add liquidity on the Ekubo app.

We have almost everything for our swap. We now need to understand this part:

```rs
SwapParameters {
        amount: token_amount.amount,
        is_token1: is_token1,
        sqrt_ratio_limit: node.sqrt_ratio_limit,
        skip_ahead: node.skip_ahead,
    }
```

- `amount`, it is of type `i129`. It "represents a signed integer in a 129 bit container, where the sign is 1 bit and the other 128 bits are magnitude".
- `is_token1`
