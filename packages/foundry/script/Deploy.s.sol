// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import "../contracts/ClawdFomo3D.sol";

contract DeployScript is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        // $CLAWD token on Base
        address clawdToken = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;

        // Dev address (receives 5% fee)
        address dev = 0x11ce532845cE0eAcdA41f72FDc1C88c335981442;

        // Timer duration: 10 minutes for testing
        uint256 timerDuration = 10 minutes;

        ClawdFomo3D fomo = new ClawdFomo3D(clawdToken, timerDuration, dev);

        console.logString(string.concat("ClawdFomo3D deployed at: ", vm.toString(address(fomo))));

        deployments.push(Deployment("ClawdFomo3D", address(fomo)));
    }

    function test() public {}
}
