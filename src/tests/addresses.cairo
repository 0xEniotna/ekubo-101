use core::traits::TryInto;

use starknet::{ClassHash, ContractAddress};

// A helper that returns a very small address, ensuring that this token is always token0 in a pair
pub fn TOKEN0_ADDRESS() -> ContractAddress {
    0x00000000000000000000000000000000000000000000000000000000000000A.try_into().unwrap()
}

pub fn ETH_ADDRESS() -> ContractAddress {
    0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()
}

pub fn USDC_ADDRESS() -> ContractAddress {
    0x053C91253BC9682c04929cA02ED00b3E423f6710D2ee7e0D5EBB06F3eCF368A8.try_into().unwrap()
}

pub fn EKUBO_CORE() -> ContractAddress {
    0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b.try_into().unwrap()
}

pub fn EKUBO_POSITIONS() -> ContractAddress {
    0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067.try_into().unwrap()
}

pub fn EKUBO_REGISTRY() -> ContractAddress {
    0x0013e25867b6eef62703735aa4cfa7754e72f4e94a56c9d3d9ad8ebe86cee4aa.try_into().unwrap()
}


pub fn EKUBO_ROUTER() -> ContractAddress {
    0x01b6f560def289b32e2a7b0920909615531a4d9d5636ca509045843559dc23d5.try_into().unwrap()
}

pub fn CUSTOM_ROUTER() -> ContractAddress {
    'router'.try_into().unwrap()
}
