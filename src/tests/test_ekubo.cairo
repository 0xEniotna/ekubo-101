use core::num::traits::zero::Zero;
use core::option::OptionTrait;
use core::traits::Into;
use core::traits::TryInto;
use core::array::ArrayTrait;

use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait,};
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use ekubo::interfaces::router::{Depth, RouteNode, TokenAmount};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait};

use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use ekubo::types::position::{Position};
use ekubo::types::fees_per_liquidity::{FeesPerLiquidity};
use snforge_std::{
    start_prank, stop_prank, start_spoof, stop_spoof, spy_events, SpyOn, EventSpy, EventAssertions,
    CheatTarget, TxInfoMock, declare, ContractClassTrait, get_class_hash, store, map_entry_address,
};
use parc_core::tests::addresses::{
    EKUBO_CORE, EKUBO_POSITIONS, EKUBO_ROUTER, EKUBO_REGISTRY, CUSTOM_ROUTER, ETH_ADDRESS,
    USDC_ADDRESS
};

use parc_core::router::{IRouterLiteDispatcher, IRouterLiteDispatcherTrait, AddLiquidity};

use starknet::{ContractAddress, contract_address_const};


impl DefaultTxInfoMock of Default<TxInfoMock> {
    fn default() -> TxInfoMock {
        TxInfoMock {
            version: Option::None(()),
            account_contract_address: Option::None(()),
            max_fee: Option::None(()),
            signature: Option::None(()),
            transaction_hash: Option::None(()),
            chain_id: Option::None(()),
            nonce: Option::None(()),
            resource_bounds: Option::None(()),
            tip: Option::None(()),
            paymaster_data: Option::None(()),
            nonce_data_availability_mode: Option::None(()),
            fee_data_availability_mode: Option::None(()),
            account_deployment_data: Option::None(()),
        }
    }
}

fn deploy_router() -> IRouterLiteDispatcher {
    let router = declare("RouterLite");
    let mut calldata = Default::default();
    Serde::serialize(@EKUBO_CORE(), ref calldata);
    let address = router.deploy_at(@calldata, CUSTOM_ROUTER()).unwrap();
    let dispatcher = IRouterLiteDispatcher { contract_address: address, };
    dispatcher
}

fn get_tokens_dispatchers() -> (IERC20Dispatcher, IERC20Dispatcher) {
    let eth = IERC20Dispatcher { contract_address: ETH_ADDRESS() };
    let usdc = IERC20Dispatcher { contract_address: USDC_ADDRESS() };
    (eth, usdc)
}

// pub struct AddLiquidity {
//     pub pool_key: PoolKey,
//     pub bounds: Bounds,
//     pub min_liquidity: u128,
//     pub amount0: u256,
//     pub amount1: u256,
//     pub referrer: ContractAddress,
// }

#[test]
#[fork("Mainnet")]
fn test_mint_liquidity_ekubo() {
    let owner = snforge_std::test_address();
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();
    let ekubo_clearer = IClearDispatcher { contract_address: router.contract_address };

    let lower_price = i129 { sign: false, mag: 1000000000000000000 };
    let upper_price = i129 { sign: false, mag: 1000000000000000000 };
    let amount_eth_in = 50000000000000000;
    let amount_usdc_in = 50000000000000000;
    store(
        eth.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_eth_in.try_into().unwrap() * 2].span()
    );
    store(
        usdc.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_usdc_in.try_into().unwrap() * 2].span()
    );

    let mint_params: AddLiquidity = AddLiquidity {
        pool_key: PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0>(),
        },
        bounds: Bounds { lower: lower_price, upper: upper_price },
        min_liquidity: 0,
        amount0: amount_eth_in,
        amount1: amount_usdc_in,
        referrer: 'ref'.try_into().unwrap(),
    };

    let (id, position) = router.mint_liquidity(mint_params);
    assert(id.is_non_zero(), 'id is zero');
}

#[test]
#[fork("Mainnet")]
fn test_swap_ekubo() {
    let owner = snforge_std::test_address();
    println!("owner: {:?}", owner);
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();
    let ekubo_clearer = IClearDispatcher { contract_address: router.contract_address };
    let amountIn: u128 = 50000000000000000;
    // let amount_felt: felt252 = amountIn.into();
    let node: RouteNode = RouteNode {
        pool_key: PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0>(),
        },
        sqrt_ratio_limit: 9518214665331634718173648621336545,
        skip_ahead: 0,
    };
    let token_amount: TokenAmount = TokenAmount {
        token: eth.contract_address, amount: i129 { mag: amountIn, sign: false },
    };

    store(
        eth.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amountIn.into() * 2].span()
    );
    let bal_owner_before_eth = eth.balanceOf(owner);
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.transfer(router.contract_address, amountIn.into());
    stop_prank(CheatTarget::One(eth.contract_address));

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(456);
    tx_info.account_contract_address = Option::Some(owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let delta = router.swap(node, token_amount);
    let bal_owner_after_eth = eth.balanceOf(owner);
    assert(
        bal_owner_after_eth == bal_owner_before_eth - amountIn.into(), 'not correct eth balance'
    );
    let bal_owner_usdc = usdc.balanceOf(owner);
    assert(bal_owner_usdc == delta.amount1.mag.into(), 'not correct usdc balance');
}

