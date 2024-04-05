use starknet::{ContractAddress, contract_address_const};
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
use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};


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

pub fn deploy_router() -> IRouterLiteDispatcher {
    let router = declare("RouterLite");
    let mut calldata = Default::default();
    Serde::serialize(@EKUBO_CORE(), ref calldata);
    Serde::serialize(@EKUBO_POSITIONS(), ref calldata);

    let address = router.deploy_at(@calldata, CUSTOM_ROUTER()).unwrap();
    let dispatcher = IRouterLiteDispatcher { contract_address: address, };
    dispatcher
}

pub fn create_mock_tx(tx_id: felt252, account: ContractAddress) -> TxInfoMock {
    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(tx_id);
    tx_info.account_contract_address = Option::Some(account);
    tx_info
}

pub fn get_tokens_dispatchers() -> (IERC20Dispatcher, IERC20Dispatcher) {
    let eth = IERC20Dispatcher { contract_address: ETH_ADDRESS() };
    let usdc = IERC20Dispatcher { contract_address: USDC_ADDRESS() };
    (eth, usdc)
}
