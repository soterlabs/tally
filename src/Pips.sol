// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pips.sol -- pricing adapters for Tally

// Copyright (C) 2026 Soter Labs
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

// Compatibility imports. New integrations can import individual adapters.
import { Pip, PipLike, TokenLike } from "./pips/Pip.sol";
import { RawPip } from "./pips/RawPip.sol";
import { Erc4626Pip, VaultLike } from "./pips/Erc4626Pip.sol";
import { Erc7540Pip, AsyncVaultLike } from "./pips/Erc7540Pip.sol";
import { ATokenPip, ATokenLike, PoolLike } from "./pips/ATokenPip.sol";
import { RelayPip } from "./pips/RelayPip.sol";
import { ChroniclePip, ChronicleLike } from "./pips/ChroniclePip.sol";
import { LendingIdlePip, ATokenSupplyLike } from "./pips/LendingIdlePip.sol";
import { CurveLegPip, CurvePoolLike, TokenSupplyLike } from "./pips/CurveLegPip.sol";
import { CapitalPip } from "./pips/CapitalPip.sol";
import { UniV3Pip, NPMLike, UniV3PoolLike } from "./pips/UniV3Pip.sol";
