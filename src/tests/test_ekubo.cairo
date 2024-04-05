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
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};

use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use ekubo::types::position::{Position};
use ekubo::types::fees_per_liquidity::{FeesPerLiquidity};
use snforge_std::{
    start_prank, stop_prank, start_spoof, stop_spoof, spy_events, SpyOn, EventSpy, EventAssertions,
    CheatTarget, TxInfoMock, declare, ContractClassTrait, get_class_hash, store, map_entry_address,
};
use ekubo101::addresses::{
    EKUBO_CORE, EKUBO_POSITIONS, EKUBO_ROUTER, EKUBO_REGISTRY, CUSTOM_ROUTER, ETH_ADDRESS,
    USDC_ADDRESS
};

use ekubo101::router::{
    IRouterLiteDispatcher, IRouterLiteDispatcherTrait, AddLiquidity, WithdrawLiquidity
};
use ekubo101::tests::utils::{create_mock_tx, deploy_router, get_tokens_dispatchers};

use starknet::{ContractAddress, contract_address_const};


#[test]
#[fork("Mainnet")]
fn test_swap_ekubo() {
    let owner = snforge_std::test_address();
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();
    let amountIn: u128 = 50000000000000000;
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

    let tx_info = create_mock_tx(123, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let delta = router.swap(node, token_amount);
    let bal_owner_after_eth = eth.balanceOf(owner);
    assert(
        bal_owner_after_eth == bal_owner_before_eth - amountIn.into(), 'not correct eth balance'
    );
    let bal_owner_usdc = usdc.balanceOf(owner);
    assert(bal_owner_usdc == delta.amount1.mag.into(), 'not correct usdc balance');
}


#[test]
#[fork("Mainnet")]
fn test_mint_liquidity_ekubo() {
    let owner = snforge_std::test_address();
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();

    let upper_price = i129 { sign: false, mag: 12624000 };
    let lower_price = i129 { sign: false, mag: 12571000 };

    let amount_eth_in = 500000000000000;
    let amount_usdc_in = 50000000000000000;
    store(
        eth.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_eth_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.transfer(router.contract_address, amount_eth_in.into());
    stop_prank(CheatTarget::One(eth.contract_address));
    store(
        usdc.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_usdc_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(usdc.contract_address), owner);
    usdc.transfer(router.contract_address, amount_usdc_in.into());
    stop_prank(CheatTarget::One(usdc.contract_address));

    let bal_router_eth = eth.balanceOf(router.contract_address);
    let bal_router_usdc = usdc.balanceOf(router.contract_address);
    assert(bal_router_eth == amount_eth_in.try_into().unwrap(), 'not correct eth balance');
    assert(bal_router_usdc == amount_usdc_in.try_into().unwrap(), 'not correct usdc balance');

    let mint_params: AddLiquidity = AddLiquidity {
        pool_key: PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0>(),
        },
        // bounds: Bounds { lower: upper_price, upper: lower_price },
        bounds: Bounds { lower: lower_price, upper: upper_price },
        min_liquidity: 0,
        amount0: amount_eth_in,
        amount1: amount_usdc_in,
        referrer: 'ref'.try_into().unwrap(),
        tokenId: 0,
    };
    let tx_info = create_mock_tx(123, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let (id, _position) = router.mint_liquidity(mint_params);
    stop_spoof(CheatTarget::One(router.contract_address));
    assert(id.is_non_zero(), 'id is zero');
}

#[test]
#[fork("Mainnet")]
fn test_add_liquidity_ekubo() {
    let owner = snforge_std::test_address();
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();

    let upper_price = i129 { sign: false, mag: 12624000 };
    let lower_price = i129 { sign: false, mag: 12571000 };

    let amount_eth_in = 500000000000000;
    let amount_usdc_in = 50000000000000000;
    store(
        eth.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_eth_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.transfer(router.contract_address, amount_eth_in.into());
    stop_prank(CheatTarget::One(eth.contract_address));
    store(
        usdc.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_usdc_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(usdc.contract_address), owner);
    usdc.transfer(router.contract_address, amount_usdc_in.into());
    stop_prank(CheatTarget::One(usdc.contract_address));

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
        tokenId: 0,
    };
    let tx_info = create_mock_tx(123, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let (id, _position) = router.mint_liquidity(mint_params);
    stop_spoof(CheatTarget::One(router.contract_address));
    assert(id.is_non_zero(), 'id is zero');

    let amount_eth_in = amount_eth_in / 2;
    let amount_usdc_in = amount_usdc_in / 2;

    let add_params: AddLiquidity = AddLiquidity {
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
        tokenId: id,
    };

    // Transfer tokens to router
    start_prank(CheatTarget::One(usdc.contract_address), owner);
    usdc.transfer(router.contract_address, amount_usdc_in.into());
    stop_prank(CheatTarget::One(usdc.contract_address));
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.transfer(router.contract_address, amount_eth_in.into());
    stop_prank(CheatTarget::One(eth.contract_address));

    // Spoof router, owner is tx.origin
    let tx_info = create_mock_tx(456, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let res = router.add_liquidity(add_params);
    stop_spoof(CheatTarget::One(router.contract_address));

    assert(res > 0, 'wrong result');
}


#[test]
#[fork("Mainnet")]
fn test_withdraw_liquidity_ekubo() {
    let owner = snforge_std::test_address();
    let router = deploy_router();
    assert(router.contract_address == CUSTOM_ROUTER(), 'not CUSTOM_ROUTER');
    let (eth, usdc) = get_tokens_dispatchers();
    let clearer = IClearDispatcher { contract_address: router.contract_address };

    let upper_price = i129 { sign: false, mag: 12624000 };
    let lower_price = i129 { sign: false, mag: 12571000 };

    let amount_eth_in = 500000000000000;
    let amount_usdc_in = 50000000000000000;
    store(
        eth.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_eth_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.transfer(router.contract_address, amount_eth_in.into());
    stop_prank(CheatTarget::One(eth.contract_address));
    store(
        usdc.contract_address,
        map_entry_address(
            selector!("ERC20_balances"), // Providing variable name
            array![owner.into()].span() // Providing mapping key
        ),
        array![amount_usdc_in.try_into().unwrap() * 2].span()
    );
    start_prank(CheatTarget::One(usdc.contract_address), owner);
    usdc.transfer(router.contract_address, amount_usdc_in.into());
    stop_prank(CheatTarget::One(usdc.contract_address));

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
        tokenId: 0,
    };
    let tx_info = create_mock_tx(123, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let (id, _position) = router.mint_liquidity(mint_params);
    stop_spoof(CheatTarget::One(router.contract_address));
    assert(id.is_non_zero(), 'id is zero');

    let withdraw_params: WithdrawLiquidity = WithdrawLiquidity {
        id: id,
        pool_key: PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0>(),
        },
        bounds: Bounds { lower: lower_price, upper: upper_price },
        liquidity: _position,
        min_token0: 0,
        min_token1: 0,
    };

    let bal_owner_eth = eth.balanceOf(owner);
    let bal_owner_usdc = usdc.balanceOf(owner);

    // Spoof router, owner is tx.origin
    let tx_info = create_mock_tx(456, owner);
    start_spoof(CheatTarget::One(router.contract_address), tx_info);
    let _res = router.withdraw_liquidity(withdraw_params);
    stop_spoof(CheatTarget::One(router.contract_address));

    // Clear tokens from the router
    clearer.clear(eth);
    clearer.clear(usdc);

    // check owner end balance
    let bal_owner_eth_after = eth.balanceOf(owner);
    let bal_owner_usdc_after = usdc.balanceOf(owner);
    let boolean = (bal_owner_eth_after > bal_owner_eth) || (bal_owner_usdc_after > bal_owner_usdc);

    assert(boolean, 'wrong eth balance');
}
