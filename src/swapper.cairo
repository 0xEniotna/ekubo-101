use ekubo::types::delta::{Delta};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use ekubo::interfaces::router::{Depth, RouteNode, TokenAmount};

use starknet::{ContractAddress};


#[derive(Serde, Drop)]
pub struct Swap {
    pub route: Array<RouteNode>,
    pub token_amount: TokenAmount,
}

#[derive(Serde, Drop)]
pub struct AddLiquidity {
    pub pair: Array<TokenAmount>,
}


#[starknet::interface]
pub trait ISwapper<TContractState> {
    // Does a single swap against a single node using tokens held by this contract, and receives the output to this contract
    fn swap(
        ref self: TContractState,
        token_to_sell: ContractAddress,
        token_to_buy: ContractAddress,
        amount: u256
    ) -> Delta;
// fn add_liquidity(ref self: TContractState, pair: AddLiquidity) -> Delta;
}

#[starknet::contract]
pub mod Swapper {
    use core::box::BoxTrait;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::components::shared_locker::{
        consume_callback_data, handle_delta, call_core_with_callback
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::i129::{i129, i129Trait};
    use starknet::syscalls::{call_contract_syscall};

    use starknet::{get_caller_address, get_contract_address, get_tx_info};

    use super::{
        ContractAddress, PoolKey, Delta, IRouterLite, RouteNode, TokenAmount, Swap, AddLiquidity
    };

    pub fn ETH_ADDRESS() -> ContractAddress {
        0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()
    }

    pub fn USDC_ADDRESS() -> ContractAddress {
        0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8.try_into().unwrap()
    }


    #[storage]
    struct Storage {
        router: IRouterLiteDispatcher,
    }

    #[constructor]
    fn constructor(ref self: ContractState, router: IRouterLiteDispatcher) {
        self.router.write(router);
    }

    #[abi(embed_v0)]
    impl SwapperImpl of ISwapper<ContractState> {
        fn swap(
            ref self: TContractState,
            token_to_sell: ContractAddress,
            token_to_buy: ContractAddress,
            amount: u256
        ) -> Delta {
            let (token0, token1) = self.sort_tokens(token_to_sell, token_to_buy);
            let node: RouteNode = RouteNode {
                pool_key: PoolKey {
                    token0: token0,
                    token1: token1,
                    fee: 170141183460469235273462165868118016,
                    tick_spacing: 1000,
                    extension: contract_address_const::<0>(),
                },
                sqrt_ratio_limit: 9518214665331634718173648621336545,
                skip_ahead: 0,
            };
            let token_amount: TokenAmount = TokenAmount {
                token: token_to_sell, amount: i129 { mag: amountIn, sign: false },
            };
            let deltas = self.router.read().swap(:node, :token_amount);
        }
    // fn add_liquidity(ref self: ContractState, pair: AddLiquidity) -> Delta {// let mut deltas: Array<Delta> = self.multihop_swap(array![node], token_amount);
    // // deltas.pop_front().unwrap()
    // }
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
