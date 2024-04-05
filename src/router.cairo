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
    pub tokenId: u64
}

#[derive(Serde, Drop, Copy)]
pub struct WithdrawLiquidity {
    pub id: u64,
    pub pool_key: PoolKey,
    pub bounds: Bounds,
    pub liquidity: u128,
    pub min_token0: u128,
    pub min_token1: u128,
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
    fn mint_liquidity(ref self: TContractState, params: AddLiquidity) -> (u64, u128);
    fn add_liquidity(ref self: TContractState, params: AddLiquidity) -> u128;
    fn withdraw_liquidity(ref self: TContractState, params: WithdrawLiquidity) -> (u128, u128);
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

    use ekubo101::addresses::{USDC_ADDRESS, ETH_ADDRESS};

    use super::{
        ContractAddress, PoolKey, Delta, IRouterLite, RouteNode, TokenAmount, Swap, AddLiquidity,
        WithdrawLiquidity
    };

    #[derive(Serde, Drop)]
    enum CallbackData {
        SwapCallback: Array<Swap>,
        MintPositionCallback: AddLiquidity,
        AddLiquiditiyCallback: AddLiquidity,
        WithdrawLiquidityCallback: WithdrawLiquidity,
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
    }

    fn swap_inner(mut swaps: Array<Swap>, core: ICoreDispatcher) -> Span<felt252> {
        // instantiate the output variable, it will hold the deltas of all swaps
        let mut outputs: Array<Array<Delta>> = ArrayTrait::new();
        // loop through all swaps
        loop {
            // all for each swap do
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
                                // Call the core swap function
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
                    // Recipient is the address that will receive the output of the swap
                    let recipient = get_tx_info().unbox().account_contract_address;

                    outputs.append(deltas);

                    let first = first_swap_amount.unwrap();
                    // handle_delta will transfer the tokens to the recipient
                    handle_delta(core, token_amount.token, -token_amount.amount, recipient);
                    handle_delta(core, first.token, first.amount, recipient);
                },
                Option::None => { break (); }
            };
        };

        // serialize and return
        let mut serialized: Array<felt252> = array![];
        Serde::serialize(@outputs, ref serialized);
        serialized.span()
    }

    fn mint_inner(
        params: AddLiquidity, core: ICoreDispatcher, position: IPositionsDispatcher
    ) -> Span<felt252> {
        let AddLiquidity { pool_key, bounds, min_liquidity, amount0, amount1, referrer, tokenId } =
            params;

        // Transfer liquidity to the position contract
        if (params.amount0 > 0) {
            let res = IERC20Dispatcher { contract_address: pool_key.token0 }
                .transfer(recipient: position.contract_address, amount: amount0);
            assert(res == true, 'Transfer failed');
        }

        if (params.amount1 > 0) {
            let res = IERC20Dispatcher { contract_address: pool_key.token1 }
                .transfer(recipient: position.contract_address, amount: amount1);
            assert(res == true, 'Transfer failed');
        }

        // Mint liquidity
        let (id, liquidity) = position
            .mint_and_deposit_with_referrer(
                pool_key, bounds, min_liquidity: min_liquidity, referrer: referrer
            );

        // Return the id and liquidity
        let mut serialized: Array<felt252> = array![];

        Serde::serialize(@id, ref serialized);
        Serde::serialize(@liquidity, ref serialized);

        serialized.span()
    }

    fn add_inner(
        params: AddLiquidity, core: ICoreDispatcher, position: IPositionsDispatcher
    ) -> Span<felt252> {
        let AddLiquidity { pool_key, bounds, min_liquidity, amount0, amount1, referrer, tokenId } =
            params;

        // Transfer liquidity to the position contract
        if (params.amount0 > 0) {
            let res = IERC20Dispatcher { contract_address: pool_key.token0 }
                .transfer(recipient: position.contract_address, amount: amount0);
            assert(res == true, 'Transfer failed');
        }

        if (params.amount1 > 0) {
            let res = IERC20Dispatcher { contract_address: pool_key.token1 }
                .transfer(recipient: position.contract_address, amount: amount1);
            assert(res == true, 'Transfer failed');
        }

        // Add liquidity to the existing pool with the given id
        let liquidity = position.deposit(tokenId, pool_key, bounds, min_liquidity: min_liquidity);

        let mut serialized: Array<felt252> = array![];

        Serde::serialize(@liquidity, ref serialized);

        serialized.span()
    }

    fn withdraw_inner(
        params: WithdrawLiquidity, core: ICoreDispatcher, position: IPositionsDispatcher
    ) -> Span<felt252> {
        // Destructure params
        let WithdrawLiquidity { id, pool_key, bounds, liquidity, min_token0, min_token1, } = params;

        // Withdraw liquidity from the pool
        let (amount0, amount1) = position
            .withdraw_v2(:id, :pool_key, :bounds, :liquidity, :min_token0, :min_token1,);

        // Router should hold the tokens now
        // The user must call "clear"
        let mut serialized: Array<felt252> = array![];

        Serde::serialize(@amount0, ref serialized);
        Serde::serialize(@amount1, ref serialized);

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
            call_core_with_callback::<
                CallbackData, Array<Array<Delta>>
            >(self.core.read(), @CallbackData::SwapCallback(swaps))
        }

        fn mint_liquidity(ref self: ContractState, params: AddLiquidity) -> (u64, u128) {
            call_core_with_callback::<
                CallbackData, (u64, u128)
            >(self.core.read(), @CallbackData::MintPositionCallback(params))
        }

        fn add_liquidity(ref self: ContractState, params: AddLiquidity) -> u128 {
            call_core_with_callback::<
                CallbackData, u128
            >(self.core.read(), @CallbackData::AddLiquiditiyCallback(params))
        }

        fn withdraw_liquidity(ref self: ContractState, params: WithdrawLiquidity) -> (u128, u128) {
            call_core_with_callback::<
                CallbackData, (u128, u128)
            >(self.core.read(), @CallbackData::WithdrawLiquidityCallback(params))
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
