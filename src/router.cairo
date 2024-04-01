use ekubo::types::delta::{Delta};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use ekubo::interfaces::router::{Depth, RouteNode, TokenAmount};
use ekubo::types::position::{Position};
use ekubo::types::fees_per_liquidity::{FeesPerLiquidity};
use ekubo::types::bounds::Bounds;

use starknet::{ContractAddress};


#[derive(Serde, Drop)]
pub struct Swap {
    pub route: Array<RouteNode>,
    pub token_amount: TokenAmount,
}


#[derive(Serde, Drop, Copy)]
pub struct AddLiquidity {
    pub pool_key: PoolKey,
    pub bounds: Bounds,
    pub min_liquidity: u128,
    pub amount0: u256,
    pub amount1: u256,
    pub referrer: ContractAddress,
}

// #[derive(Serde, Drop, Copy)]
// pub struct MintPosition {
//     pub pool_key: PoolKey,
//     pub bounds: Bounds,
//     pub min_liquidity: u64,
//     pub referrer: ContractAddress,
// }

#[derive(Copy, Drop, Serde)]
struct EkuboLP {
    owner: ContractAddress,
    quote_address: ContractAddress,
    pool_key: PoolKey,
    bounds: Bounds,
}


#[starknet::interface]
pub trait IRouterLite<TContractState> {
    // Does a single swap against a single node using tokens held by this contract, and receives the output to this contract
    fn swap(ref self: TContractState, node: RouteNode, token_amount: TokenAmount) -> Delta;
    // Does a multihop swap, where the output/input of each hop is passed as input/output of the next swap
    // Note to do exact output swaps, the route must be given in reverse
    fn multihop_swap(
        ref self: TContractState, route: Array<RouteNode>, token_amount: TokenAmount
    ) -> Array<Delta>;

    // Does multiple multihop swaps
    fn multi_multihop_swap(ref self: TContractState, swaps: Array<Swap>) -> Array<Array<Delta>>;
    fn mint_liquidity(ref self: TContractState, pair: AddLiquidity) -> (u64, EkuboLP);
    fn update_liquidity(ref self: TContractState, pair: AddLiquidity) -> (u64, EkuboLP);
}

#[starknet::contract]
pub mod RouterLite {
    use core::box::BoxTrait;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::components::shared_locker::{
        consume_callback_data, handle_delta, call_core_with_callback
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::i129::{i129, i129Trait};
    use ekubo::types::position::{Position};
    use ekubo::types::fees_per_liquidity::{FeesPerLiquidity};
    use starknet::syscalls::{call_contract_syscall};

    use starknet::{get_caller_address, get_contract_address, get_tx_info};

    use super::{
        ContractAddress, PoolKey, Delta, IRouterLite, RouteNode, TokenAmount, Swap, AddLiquidity,
        EkuboLP
    };

    pub fn ETH_ADDRESS() -> ContractAddress {
        0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()
    }

    pub fn USDC_ADDRESS() -> ContractAddress {
        0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8.try_into().unwrap()
    }


    #[derive(Serde, Drop)]
    enum CallbackData {
        SwapCallback: Array<Swap>,
        MintPositionCallback: AddLiquidity,
        AddLiquidityCallback: AddLiquidity,
        WithdrawLiquidityCallback: AddLiquidity,
    }

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        position: IPositionsDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, core: ICoreDispatcher, position: IPositionsDispatcher) {
        self.core.write(core);
        self.position.write(position);
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // let mut answer = consume_callback_data::<Array<Swap>>(core, data);
            let mut answer = consume_callback_data::<CallbackData>(core, data);

            match answer {
                CallbackData::SwapCallback(swaps) => { swap_inner(swaps, core) },
                CallbackData::MintPositionCallback(params) => {
                    let position_contract = self.position.read();
                    mint_inner(params, core, position_contract)
                },
                CallbackData::AddLiquidityCallback(params) => {
                    let position_contract = self.position.read();

                    if (params.amount0 > 0) {
                        IERC20Dispatcher { contract_address: params.pool_key.token0 }
                            .transfer(
                                recipient: position_contract.contract_address,
                                amount: params.amount0
                            );
                    }

                    if (params.amount1 > 0) {
                        IERC20Dispatcher { contract_address: params.pool_key.token1 }
                            .transfer(
                                recipient: position_contract.contract_address,
                                amount: params.amount1
                            );
                    }
                    let (id, liquidity) = position_contract
                        .mint_and_deposit_with_referrer(
                            params.pool_key,
                            params.bounds,
                            min_liquidity: 0,
                            referrer: 'ref'.try_into().unwrap()
                        );

                    let mut serialized: Array<felt252> = array![];

                    Serde::serialize(@id, ref serialized);
                    Serde::serialize(@liquidity, ref serialized);

                    serialized.span()
                },
                CallbackData::WithdrawLiquidityCallback(params) => {
                    let position_contract = self.position.read();

                    if (params.amount0 > 0) {
                        IERC20Dispatcher { contract_address: params.pool_key.token0 }
                            .transfer(
                                recipient: position_contract.contract_address,
                                amount: params.amount0
                            );
                    }

                    if (params.amount1 > 0) {
                        IERC20Dispatcher { contract_address: params.pool_key.token1 }
                            .transfer(
                                recipient: position_contract.contract_address,
                                amount: params.amount1
                            );
                    }
                    let (id, liquidity) = position_contract
                        .mint_and_deposit_with_referrer(
                            params.pool_key,
                            params.bounds,
                            min_liquidity: 0,
                            referrer: 'ref'.try_into().unwrap()
                        );

                    let mut serialized: Array<felt252> = array![];

                    Serde::serialize(@id, ref serialized);
                    Serde::serialize(@liquidity, ref serialized);

                    serialized.span()
                },
            }
        }
    }

    fn swap_inner(swaps: Array<Swap>, core: ICoreDispatcher) -> Span<felt252> {
        let mut outputs: Array<Array<Delta>> = ArrayTrait::new();
        let mut swaps = swaps;
        loop {
            match swaps.pop_front() {
                Option::Some(swap) => {
                    let mut route = swap.route;
                    let mut token_amount = swap.token_amount;

                    let mut deltas: Array<Delta> = ArrayTrait::new();
                    // we track this to know how much to pay in the case of exact input and how much to pull in the case of exact output
                    let mut first_swap_amount: Option<TokenAmount> = Option::None;
                    loop {
                        match route.pop_front() {
                            Option::Some(node) => {
                                let is_token1 = token_amount.token == node.pool_key.token1;
                                let delta = core
                                    .swap(
                                        node.pool_key,
                                        SwapParameters {
                                            amount: token_amount.amount,
                                            is_token1: is_token1,
                                            sqrt_ratio_limit: node.sqrt_ratio_limit,
                                            skip_ahead: node.skip_ahead,
                                        }
                                    );
                                deltas.append(delta);

                                if first_swap_amount.is_none() {
                                    first_swap_amount =
                                        if is_token1 {
                                            Option::Some(
                                                TokenAmount {
                                                    token: node.pool_key.token1,
                                                    amount: delta.amount1
                                                }
                                            )
                                        } else {
                                            Option::Some(
                                                TokenAmount {
                                                    token: node.pool_key.token0,
                                                    amount: delta.amount0
                                                }
                                            )
                                        }
                                }

                                token_amount =
                                    if (is_token1) {
                                        TokenAmount {
                                            amount: -delta.amount0, token: node.pool_key.token0
                                        }
                                    } else {
                                        TokenAmount {
                                            amount: -delta.amount1, token: node.pool_key.token1
                                        }
                                    };
                            },
                            Option::None => { break (); }
                        };
                    };

                    let recipient = get_tx_info().unbox().account_contract_address;

                    outputs.append(deltas);

                    let first = first_swap_amount.unwrap();
                    handle_delta(core, token_amount.token, -token_amount.amount, recipient);
                    handle_delta(core, first.token, first.amount, recipient);
                },
                Option::None => { break (); }
            };
        };
        let mut serialized: Array<felt252> = array![];

        Serde::serialize(@outputs, ref serialized);
        serialized.span()
    }

    fn mint_inner(
        params: AddLiquidity, core: ICoreDispatcher, position: IPositionsDispatcher
    ) -> Span<felt252> {
        if (params.amount0 > 0) {
            IERC20Dispatcher { contract_address: params.pool_key.token0 }
                .transfer(recipient: position.contract_address, amount: params.amount0);
        }

        if (params.amount1 > 0) {
            IERC20Dispatcher { contract_address: params.pool_key.token1 }
                .transfer(recipient: position.contract_address, amount: params.amount1);
        }
        let (id, liquidity) = position
            .mint_and_deposit_with_referrer(
                params.pool_key,
                params.bounds,
                min_liquidity: params.min_liquidity,
                referrer: params.referrer
            );

        let mut serialized: Array<felt252> = array![];

        Serde::serialize(@id, ref serialized);
        Serde::serialize(@liquidity, ref serialized);

        serialized.span()
    }


    #[abi(embed_v0)]
    impl RouterLiteImpl of IRouterLite<ContractState> {
        fn swap(ref self: ContractState, node: RouteNode, token_amount: TokenAmount) -> Delta {
            let mut deltas: Array<Delta> = self.multihop_swap(array![node], token_amount);
            deltas.pop_front().unwrap()
        }

        #[inline(always)]
        fn multihop_swap(
            ref self: ContractState, route: Array<RouteNode>, token_amount: TokenAmount
        ) -> Array<Delta> {
            let mut result = self.multi_multihop_swap(array![Swap { route, token_amount }]);
            result.pop_front().unwrap()
        }

        #[inline(always)]
        fn multi_multihop_swap(ref self: ContractState, swaps: Array<Swap>) -> Array<Array<Delta>> {
            call_core_with_callback(self.core.read(), @swaps)
        }

        fn mint_liquidity(ref self: ContractState, pair: AddLiquidity) -> (u64, EkuboLP) {
            let (id, position) = call_core_with_callback::<
                CallbackData, (u64, EkuboLP)
            >(self.core.read(), @CallbackData::MintPositionCallback(pair));
            return (id, position);
        }

        fn update_liquidity(ref self: ContractState, pair: AddLiquidity) -> (u64, EkuboLP) {
            let (id, position) = call_core_with_callback::<
                CallbackData, (u64, EkuboLP)
            >(self.core.read(), @CallbackData::AddLiquidityCallback(pair));
            return (id, position);
        }
    }
    fn sort_tokens(
        tokenA: ContractAddress, tokenB: ContractAddress
    ) -> (ContractAddress, ContractAddress) {
        if tokenA < tokenB {
            (tokenA, tokenB)
        } else {
            (tokenB, tokenA)
        }
    }
}
