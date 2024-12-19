use core::starknet::ContractAddress;

// TODO: Add the correct type for L1Address
type L1Address = u256;

#[starknet::interface]
pub trait IBridgePOC<TContractState> {
    fn deposit(ref self: TContractState, recipient: ContractAddress, amount: u256) {}
    fn withdraw(ref self: TContractState, recipient: L1Address, amount: u256) {}
}

#[starknet::contract]
pub mod BridgePOC {
    use core::num::traits::zero::Zero;
    use starknet::storage::VecTrait;
    use core::starknet::ContractAddress;
    use crate::hash::{Digest, DigestTrait};
    use super::L1Address;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, MutableVecTrait,
    };
    use crate::double_sha256::double_sha256_digests;

    // TODO: this should be declared in InternalImpl
    pub const TREE_HEIGHT: u8 = 10;

    // Branch of a merkle tree of withdrawal requests. Uses algo described here:
    // https://github.com/ethereum/research/blob/a4a600f2869feed5bfaab24b13ca1692069ef312/beacon_chain_impl/progressive_merkle_tree.py
    // https://www.youtube.com/watch?v=nZ8cquX5kew&ab_channel=FormalMethodsEurope
    #[phantom]
    #[starknet::storage_node]
    struct Branch {
        elements: Vec<Digest>,
        size: u16,
    }

    #[storage]
    struct Storage {
        withdrawals: Branch,
    }

    #[abi(embed_v0)]
    impl BridgePOC of super::IBridgePOC<ContractState> {
        fn deposit(ref self: ContractState, recipient: ContractAddress, amount: u256) {}
        fn withdraw(ref self: ContractState, recipient: L1Address, amount: u256) {}
    }

    #[generate_trait]
    pub impl InternalImpl of InternalTrait {
        // TODO: how to enforce ZERO_HASHES.len() == TREE_HEIGHT?
        // calculated with print_zero_hashes below
        #[cairofmt::skip]
        const ZERO_HASHES: [[u32; 8]; 10] = [
            [0, 0, 0, 0, 0, 0, 0, 0],
            [3807779903, 1909579517, 1068079583, 2741588853, 1550386825, 2040095412, 2347489334, 2538507513],
            [2099567403, 4198582091, 4214196093, 1754246239, 2858291362, 2156722654, 812871865, 861070664],
            [2491776318, 143757168, 962433542, 1091551145, 1123133577, 2858072088, 2395159599, 1847623111],
            [431952387, 3552528441, 1013566501, 1502155963, 2651664431, 910006309, 3684743675, 2510070587],
            [2911086469, 1887493546, 3378700630, 3912122119, 3565730943, 113941511, 247519979, 1936780936],
            [4149171068, 670075167, 4270418929, 385287363, 953086358, 3888476695, 4151032589, 3608278989],
            [1723082150, 3777628280, 2788800972, 2132291431, 4168203796, 2521771669, 2723785127, 1542325057],
            [1829197597, 3996005857, 931906618, 2383644882, 4277580546, 482972235, 2287817650, 3459845800],
            [2257188826, 1732868934, 4244326882, 39139633, 3210730636, 2509762326, 1485744241, 392942686],
        ];

        fn get_element(self: @ContractState, i: u64) -> Digest {
            match self.withdrawals.elements.get(i) {
                Option::Some(element) => element.read(),
                Option::None => {
                    panic!("should not happen!");
                    Zero::zero()
                },
            }
        }

        fn append(ref self: ContractState, withdrawal: Digest) {
            //TODO: make sure it is not full
            let mut value = withdrawal;
            let original_size = self.withdrawals.size.read();
            let mut size = original_size;
            let mut i = 0;

            while size % 2 == 1 {
                value = double_sha256_digests(@self.get_element(i), @value);
                size = size / 2;
                i += 1;
            };

            if i >= self.withdrawals.elements.len() {
                self.withdrawals.elements.append().write(value);
            } else {
                self.withdrawals.elements.at(i).write(value);
            }
            self.withdrawals.size.write(original_size + 1);
        }

        fn root(self: @ContractState) -> Digest {
            let zero_hashes = Self::ZERO_HASHES.span();

            let mut root = DigestTrait::new(*zero_hashes.at(0));
            let mut height = 0;
            let mut size = self.withdrawals.size.read();

            while height < TREE_HEIGHT.into() {
                if size % 2 == 1 {
                    root = double_sha256_digests(@self.get_element(height.into()), @root);
                } else {
                    root = double_sha256_digests(@root, @DigestTrait::new(*zero_hashes.at(height)));
                }
                size = size / 2;
                height += 1;
            };

            root
        }
    }
}

#[cfg(test)]
mod merkle_tree_tests {
    use crate::hash::{Digest, DigestTrait};
    use crate::double_sha256::double_sha256_digests;
    use super::{BridgePOC};
    use super::BridgePOC::InternalTrait;
    use crate::bit_shifts::pow2;

    fn merkle_root(hashes: Span<Digest>) -> Digest {
        let zero_hash = DigestTrait::new([0; 8]);
        let mut hashes: Array<Digest> = hashes.into();

        let expected_size = pow2(BridgePOC::TREE_HEIGHT.into());
        for _ in 0..(expected_size - hashes.len().into()) {
            hashes.append(zero_hash);
        };

        let mut hashes = hashes.span();

        for _ in 0..BridgePOC::TREE_HEIGHT {
            let mut next_hashes: Array<Digest> = array![];
            while let Option::Some(v) = hashes.multi_pop_front::<2>() {
                let [a, b] = (*v).unbox();
                next_hashes.append(double_sha256_digests(@a, @b));
            };
            hashes = next_hashes.span();
        };

        *hashes.at(0)
    }

    // use this to fill the ZERO_HASHES array
    #[test]
    #[ignore]
    fn print_zero_hashes() {
        let mut previous: Digest = 0_u256.into();
        for _ in 0..BridgePOC::TREE_HEIGHT {
            previous = double_sha256_digests(@previous, @previous);
        }
    }

    fn data(size: u256) -> Array<Digest> {
        let x = 0x8000000000000000000000000000000000000000000000000000000000000000;
        let mut r = array![];
        for i in 1..size + 1 {
            r.append((x + i).into());
        };
        r
    }

    fn test_data(size: u256) {
        let data = data(size).span();

        let mut bridge = BridgePOC::contract_state_for_testing();

        for d in data {
            bridge.append(*d);
        };

        assert_eq!(bridge.root(), merkle_root(data), "merkle root mismatch");
    }

    #[test]
    fn test_merkle_root1() {
        test_data(1);
    }

    #[test]
    fn test_merkle_root2() {
        test_data(2);
    }

    #[test]
    fn test_merkle_root3() {
        test_data(3);
    }

    #[test]
    fn test_merkle_root256() {
        test_data(256);
    }

    fn test_merkle_root1023() {
        test_data(1023);
    }
}

#[cfg(test)]
mod bridge_tests {
    fn test_deposit() { // let bridge_class = declare("BridgePOC").unwrap().contract_class();
    // let bridge_address = bridge_class.deploy(@array![]).unwrap();
    // let bridge = IBridgePOCDispather(contract_address);
    }
}
