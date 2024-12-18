use core::starknet::ContractAddress;

// TODO: Add the correct type for L1Address
type L1Address = u256;

#[starknet::interface]
trait IBridgePOC<TContractState> {
    fn deposit(ref self: TContractState, recipient: ContractAddress, amount: u256) {}
    fn withdraw(ref self: TContractState, recipient: L1Address, amount: u256) {}
}


#[starknet::contract]
mod BridgePOC {
    use starknet::storage::VecTrait;
    use core::starknet::ContractAddress;
    use crate::hash::{Digest, DigestTrait};
    use super::L1Address;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, MutableVecTrait,
    };
    use crate::double_sha256::double_sha256_digests;
    use core::num::traits::Bounded;

    // TODO: this should be declared in InternalImpl
    pub const TREE_HEIGHT: u8 = 16;

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
    impl InternalImpl of InternalTrait {
        // TODO: how to enforce ZERO_HASHES.len() == TREE_HEIGHT?
        #[cairofmt::skip]
        const ZERO_HASHES: [[u32; 8]; 16] = [
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
            [2184653188, 4257042108, 677354460, 2465790105, 2048605806, 2745285032, 3104182931, 15402110],
            [2860792224, 1687116504, 4231068254, 1935089599, 3765226240, 2947536533, 2517980564, 218435369],
            [1926580722, 2072212521, 1018304954, 168205711, 57131430, 3740386295, 3329007170, 530668389],
            [2270689968, 3288476717, 2865565625, 3616230225, 4127251747, 557907537, 780565330, 718131277],
            [738994716, 1806310578, 2743103358, 3990199691, 371481172, 913060570, 163698502, 1078340806],
            [770758798, 2266110520, 184798668, 311383229, 734089413, 4172582247, 2839721722, 4005778739]
        ];

        fn append(ref self: ContractState, withdrawal: Digest) {
            let mut value = withdrawal;
            let original_size = self.withdrawals.size.read();

            // TODO: close the queue when it's full?
            if original_size == Bounded::<u16>::MAX {
                panic!("BridgePoc::withdrawals queue is full");
            }

            let mut size = original_size;
            let mut i = 0;

            while size % 2 == 1 {
                let element = self.withdrawals.elements.at(i).read();
                value = double_sha256_digests(@element, @value);
                size = size / 2;
                i += 1;
            };

            self.withdrawals.elements.at(i).write(value);
            self.withdrawals.size.write(original_size + 1);
        }

        fn root(self: @ContractState) -> Digest {
            let zero_hashes = Self::ZERO_HASHES.span();

            let mut root = DigestTrait::new(*zero_hashes.at(0));

            let mut height = 0;
            let mut size = self.withdrawals.size.read();

            while height < super::BridgePOC::TREE_HEIGHT.into() {
                if size % 2 == 1 {
                    let element = self.withdrawals.elements.at(height.into()).read();
                    root = double_sha256_digests(@element, @root);
                } else {
                    let zero_hash = DigestTrait::new(*zero_hashes.at(height));
                    root = double_sha256_digests(@root, @zero_hash);
                }
                size = size / 2;
                height += 1;
            };

            root
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::hash::Digest;
    use crate::double_sha256::double_sha256_digests;
    use super::BridgePOC;

    // use this to fill the ZERO_HASHES array
    #[test]
    #[ignore]
    fn print_zero_hashes() {
        let mut previous: Digest = 0_u256.into();
        for i in 0..BridgePOC::TREE_HEIGHT {
            println!("zero_hashes[{}] = {:?}", i, previous);
            previous = double_sha256_digests(@previous, @previous);
        }
    }
}
