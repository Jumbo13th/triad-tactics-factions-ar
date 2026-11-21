modded class RHS_HearingManager
{
	//------------------------------------------------------------------------------------------------
	// The manager is the only writer of the SFX/Dialog master volume, the dynamic range signal and the
	// tinnitus signal, and the only listener of the level key. Without an instance every shot report is
	// dropped and the player's own audio settings stay in force.
	static override void Start()
	{
	}
}

modded class RHS_HearingProtectionComponent
{
	//------------------------------------------------------------------------------------------------
	// Headsets stay on the prefabs as plain headgear. The level actions, the key hint and the HUD
	// indicator all resolve the worn device through this lookup, so none of them appears.
	static override RHS_HearingProtectionComponent GetWornBy(IEntity character)
	{
		return null;
	}
}
