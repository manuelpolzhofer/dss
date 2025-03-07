/// end.sol -- global settlement engine

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2018 Lev Livnev <lev@liv.nev.org.uk>
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

pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./lib.sol";

contract VatLike {
    struct Ilk {
        uint256 Art;
        uint256 rate;
        uint256 spot;
        uint256 line;
        uint256 dust;
    }
    struct Urn {
        uint256 ink;
        uint256 art;
    }
    function dai(address) public view returns (uint);
    function ilks(bytes32 ilk) public returns (Ilk memory);
    function urns(bytes32 ilk, address urn) public returns (Urn memory);
    function debt() public returns (uint);
    function move(address src, address dst, uint256 rad) public;
    function hope(address) public;
    function flux(bytes32 ilk, address src, address dst, uint256 rad) public;
    function grab(bytes32 i, address u, address v, address w, int256 dink, int256 dart) public;
    function suck(address u, address v, uint256 rad) public;
    function cage() public;
}
contract CatLike {
    struct Ilk {
        address flip;  // Liquidator
        uint256 chop;  // Liquidation Penalty   [ray]
        uint256 lump;  // Liquidation Quantity  [rad]
    }
    function ilks(bytes32) public returns (Ilk memory);
    function cage() public;
}
contract VowLike {
    function heal(uint256 rad) public;
    function cage() public;
}
contract Flippy {
    struct Bid {
        uint256 bid;
        uint256 lot;
        address guy;
        uint48  tic;
        uint48  end;
        address urn;
        address gal;
        uint256 tab;
    }
    function bids(uint id) public view returns (Bid memory);
    function yank(uint id) public;
}

contract PipLike {
    function read() public view returns (bytes32);
}

contract Spotty {
    struct Ilk {
        PipLike pip;
        uint256 mat;
    }
    function ilks(bytes32) public view returns (Ilk memory);
}

/*
    This is the `End` and it coordinates Global Settlement. This is an
    involved, stateful process that takes place over nine steps.

    First we freeze the system and lock the prices for each ilk.

    1. `cage()`:
        - freezes user entrypoints
        - cancels flop/flap auctions
        - starts cooldown period

    2. `cage(ilk)`:
       - set the cage price for each `ilk`, reading off the price feed

    We must process some system state before it is possible to calculate
    the final dai / collateral price. In particular, we need to determine

      a. `gap`, the collateral shortfall per collateral type by
         considering under-collateralised CDPs.

      b. `debt`, the outstanding dai supply after including system
         surplus / deficit

    We determine (a) by processing all under-collateralised CDPs with
    `skim`:

    3. `skim(ilk, urn)`:
       - cancels CDP debt
       - any excess collateral remains
       - backing collateral taken

    We determine (b) by processing ongoing dai generating processes,
    i.e. auctions. We need to ensure that auctions will not generate any
    further dai income. In the two-way auction model this occurs when
    all auctions are in the reverse (`dent`) phase. There are two ways
    of ensuring this: a) set the cooldown period to be at least as long
    as the longest auction duration, which needs to be determined by the
    cage administrator, and b) cancel all ongoing auctions and seize the
    collateral.

    Option (a) takes a fairly predictable time to occur but with altered
    auction dynamics due to the now varying price of dai, whereas option
    (b) is accelerated allowing for faster processing at the expense
    of more processing calls. Option (b) allows dai holders to retrieve
    their collateral faster.

    4. a. Wait until all auctions have reached their end; OR

       b. Cancel live auctions
          `skip(ilk, id)`:
           - cancel individual flip auctions in the `tend` (forward) phase
           - retrieves collateral and returns dai to bidder
           - `dent` (reverse) phase auctions can continue normally

    When a CDP has been processed and has no debt remaining, the
    remaining collateral can be removed.

    5. `free(ilk)`:
        - remove collateral from the caller's CDP
        - owner can call as needed

    After the processing period has elapsed, we enable calculation of
    the final price for each collateral type.

    6. `thaw()`:
       - only callable after processing time period elapsed
       - assumption that all under-collateralised CDPs are processed
       - fixes the total outstanding supply of dai
       - may also require extra CDP processing to cover vow surplus

    7. `flow(ilk)`:
        - calculate the `fix`, the cash price for a given ilk
        - adjusts the `fix` in the case of deficit / surplus

    At this point we have computed the final price for each collateral
    type and dai holders can now turn their dai into collateral. Each
    unit dai can claim a fixed basket of collateral.

    Dai holders must first `pack` some dai into a `bag`. Once packed,
    dai cannot be unpacked and is not transferrable. More dai can be
    added to a bag later.

    8. `pack(wad)`:
        - put some dai into a bag in preparation for `cash`

    Finally, collateral can be obtained with `cash`. The bigger the bag,
    the more collateral can be released.

    9. `cash(ilk, wad)`:
        - exchange some dai from your bag for gems from a specific ilk
        - the number of gems is limited by how big your bag is
*/

contract End is DSNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address guy) public note auth { wards[guy] = 1; }
    function deny(address guy) public note auth { wards[guy] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Data ---
    VatLike  public vat;
    CatLike  public cat;
    VowLike  public vow;
    Spotty   public spot;

    uint256  public live;  // cage flag
    uint256  public when;  // time of cage
    uint256  public wait;  // processing cooldown length
    uint256  public debt;  // total outstanding dai following processing [rad]

    mapping (bytes32 => uint256) public tag;  // cage price           [ray]
    mapping (bytes32 => uint256) public gap;  // collateral shortfall [wad]
    mapping (bytes32 => uint256) public Art;  // total debt per ilk   [wad]
    mapping (bytes32 => uint256) public fix;  // final cash price     [ray]

    mapping (address => uint256)                      public bag;  // [wad]
    mapping (bytes32 => mapping (address => uint256)) public out;  // [wad]

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        live = 1;
    }

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function min(uint x, uint y) internal pure returns (uint z) {
        return x <= y ? x : y;
    }
    uint constant WAD = 10 ** 18;
    uint constant RAY = 10 ** 27;
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, RAY) / y;
    }

    // --- Administration ---
    function file(bytes32 what, address data) public note auth {
        if (what == "vat")  vat = VatLike(data);
        if (what == "cat")  cat = CatLike(data);
        if (what == "vow")  vow = VowLike(data);
        if (what == "spot") spot = Spotty(data);
    }
    function file(bytes32 what, uint256 data) public note auth {
        if (what == "wait") wait = data;
    }

    // --- Settlement ---
    function cage() public note auth {
        require(live == 1);
        live = 0;
        when = now;
        vat.cage();
        cat.cage();
        vow.cage();
    }

    function cage(bytes32 ilk) public note {
        require(live == 0);
        require(tag[ilk] == 0);
        Art[ilk] = vat.ilks(ilk).Art;
        // pip returns a wad, invert it and convert to ray
        tag[ilk] = rdiv(WAD, uint(spot.ilks(ilk).pip.read()));
    }

    function skip(bytes32 ilk, uint256 id) public note {
        require(tag[ilk] != 0);

        Flippy flip = Flippy(cat.ilks(ilk).flip);
        VatLike.Ilk memory i   = vat.ilks(ilk);
        Flippy.Bid  memory bid = flip.bids(id);

        vat.suck(address(vow), address(vow),  bid.tab);
        vat.suck(address(vow), address(this), bid.bid);
        vat.hope(address(flip));
        flip.yank(id);

        uint lot = bid.lot;
        uint art = bid.tab / i.rate;
        Art[ilk] = add(Art[ilk], art);
        require(int(lot) >= 0 && int(art) >= 0);
        vat.grab(ilk, bid.urn, address(this), address(vow), int(lot), int(art));
    }

    function skim(bytes32 ilk, address urn) public note {
        require(tag[ilk] != 0);
        VatLike.Ilk memory i = vat.ilks(ilk);
        VatLike.Urn memory u = vat.urns(ilk, urn);

        uint owe = rmul(rmul(u.art, i.rate), tag[ilk]);
        uint wad = min(u.ink, owe);
        gap[ilk] = add(gap[ilk], sub(owe, wad));

        require(wad <= 2**255 && u.art <= 2**255);
        vat.grab(ilk, urn, address(this), address(vow), -int(wad), -int(u.art));
    }

    function free(bytes32 ilk) public note {
        require(live == 0);
        VatLike.Urn memory u = vat.urns(ilk, msg.sender);
        require(u.art == 0);
        require(u.ink <= 2**255);
        vat.grab(ilk, msg.sender, msg.sender, address(vow), -int(u.ink), 0);
    }

    function thaw() public note {
        require(live == 0);
        require(debt == 0);
        require(vat.dai(address(vow)) == 0);
        require(now >= add(when, wait));
        debt = vat.debt();
    }
    function flow(bytes32 ilk) public note {
        require(debt != 0);
        require(fix[ilk] == 0);

        VatLike.Ilk memory i = vat.ilks(ilk);
        uint256 wad = rmul(rmul(Art[ilk], i.rate), tag[ilk]);
        fix[ilk] = rdiv(mul(sub(wad, gap[ilk]), RAY), debt);
    }

    function pack(uint256 wad) public note {
        require(debt != 0);
        vat.move(msg.sender, address(vow), mul(wad, RAY));
        bag[msg.sender] = add(bag[msg.sender], wad);
    }
    function cash(bytes32 ilk, uint wad) public note {
        require(fix[ilk] != 0);
        vat.flux(ilk, address(this), msg.sender, rmul(wad, fix[ilk]));
        out[ilk][msg.sender] = add(out[ilk][msg.sender], wad);
        require(out[ilk][msg.sender] <= bag[msg.sender]);
    }
}
