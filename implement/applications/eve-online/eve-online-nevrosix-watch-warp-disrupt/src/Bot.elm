{- EVE Online mining bot version 2020-03-27 🎉🎉

   The bot warps to an asteroid belt, mines there until the ore hold is full, and then docks at a station to unload the ore. It then repeats this cycle until you stop it.
   It remembers the station in which it was last docked, and docks again at the same station.

   Setup instructions for the EVE Online client:
   + Set the UI language to English.
   + In Overview window, make asteroids visible.
   + Set the Overview window to sort objects in space by distance with the nearest entry at the top.
   + Open one inventory window.
   + In the ship UI, arrange the modules:
     + Place all mining modules (to activate on targets) in the top row.
     + Place modules that should always be active in the middle row.
     + Hide passive modules by disabling the check-box `Display Passive Modules`.
   + Enable the info panel 'System info'.
-}
{-
   bot-catalog-tags:eve-online,mining
   authors-forum-usernames:viir
-}


module Bot exposing
    ( State
    , initState
    , processEvent
    )

import BotEngine.Interface_To_Host_20200318 as InterfaceToHost
import Dict
import EveOnline.BotFramework exposing (BotEffect(..), getEntropyIntFromUserInterface)
import EveOnline.ParseUserInterface
    exposing
        ( MaybeVisible(..)
        , OverviewWindowEntry
        , ParsedUserInterface
        , centerFromDisplayRegion
        , maybeNothingFromCanNotSeeIt
        , maybeVisibleAndThen
        )
import EveOnline.VolatileHostInterface as VolatileHostInterface exposing (MouseButton(..), effectMouseClickAtLocation)
import Result.Extra


{-| Sources for the defaults:

  - <https://forum.botengine.org/t/mining-bot-wont-approach/3162>

-}
defaultBotSettings : BotSettings
defaultBotSettings =
    { runAwayShieldHitpointsThresholdPercent = 50
    , targetingRange = 8000
    , miningModuleRange = 5000
    , botStepDelayMilliseconds = 2000
    , lastDockedStationNameFromInfoPanel = Nothing
    }


{-| Names to support with the `--app-settings`, see <https://github.com/Viir/bots/blob/master/guide/how-to-run-a-bot.md#configuring-a-bot>
-}
parseBotSettingsNames : Dict.Dict String (String -> Result String (BotSettings -> BotSettings))
parseBotSettingsNames =
    [ ( "run-away-shield-hitpoints-threshold-percent"
      , parseBotSettingInt (\threshold settings -> { settings | runAwayShieldHitpointsThresholdPercent = threshold })
      )
    , ( "targeting-range"
      , parseBotSettingInt (\range settings -> { settings | targetingRange = range })
      )
    , ( "mining-module-range"
      , parseBotSettingInt (\range settings -> { settings | miningModuleRange = range })
      )
    , ( "bot-step-delay"
      , parseBotSettingInt (\delay settings -> { settings | botStepDelayMilliseconds = delay })
      )
    , ( "last-docked-station-name-from-info-panel"
      , \stationName -> Ok (\settings -> { settings | lastDockedStationNameFromInfoPanel = Just stationName })
      )
    ]
        |> Dict.fromList


type alias BotSettings =
    { runAwayShieldHitpointsThresholdPercent : Int
    , targetingRange : Int
    , miningModuleRange : Int
    , botStepDelayMilliseconds : Int
    , lastDockedStationNameFromInfoPanel : Maybe String
    }


type alias BotMemory =
    { lastDockedStationNameFromInfoPanel : Maybe String
    }


type alias BotDecisionContext =
    { settings : BotSettings
    , memory : BotMemory
    , parsedUserInterface : ParsedUserInterface
    }


type alias UIElement =
    EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion


type alias TreeLeafAct =
    { actionsForCurrentReading : ( String, List VolatileHostInterface.EffectOnWindowStructure )
    , actionsForFollowingReadings : List ( String, ParsedUserInterface -> Maybe (List VolatileHostInterface.EffectOnWindowStructure) )
    }


type EndDecisionPathStructure
    = Wait
    | Act TreeLeafAct


type DecisionPathNode
    = DescribeBranch String DecisionPathNode
    | EndDecisionPath EndDecisionPathStructure


type alias BotState =
    { programState :
        Maybe
            { originalDecision : DecisionPathNode
            , remainingActions : List ( String, ParsedUserInterface -> Maybe (List VolatileHostInterface.EffectOnWindowStructure) )
            }
    , botMemory : BotMemory
    }


type alias State =
    EveOnline.BotFramework.StateIncludingFramework BotState


{-| A first outline of the decision tree for a mining bot came from <https://forum.botengine.org/t/how-to-automate-mining-asteroids-in-eve-online/628/109?u=viir>
-}
decideNextAction : BotDecisionContext -> DecisionPathNode
decideNextAction context =
    branchDependingOnDockedOrInSpace
        (DescribeBranch "I see no ship UI, assume we are docked."
            (ensureOreHoldIsSelected context.parsedUserInterface (decideNextActionWhenDocked context.parsedUserInterface))
        )
        (\shipUI ->
            if shipUI.hitpointsPercent.shield < context.settings.runAwayShieldHitpointsThresholdPercent then
                Just
                    (DescribeBranch
                        ("Shield hitpoints are below " ++ (context.settings.runAwayShieldHitpointsThresholdPercent |> String.fromInt) ++ "% , run away.")
                        (runAway context)
                    )

            else
                Nothing
        )
        (\seeUndockingComplete ->
            DescribeBranch "I see we are in space, undocking complete."
                (ensureOreHoldIsSelected context.parsedUserInterface (decideNextActionWhenInSpace context seeUndockingComplete))
        )
        context.parsedUserInterface


decideNextActionWhenDocked : ParsedUserInterface -> DecisionPathNode
decideNextActionWhenDocked parsedUserInterface =
    case parsedUserInterface |> inventoryWindowItemHangar of
        Nothing ->
            DescribeBranch "I do not see the item hangar in the inventory." (EndDecisionPath Wait)

        Just itemHangar ->
            case parsedUserInterface |> inventoryWindowSelectedContainerFirstItem of
                Nothing ->
                    DescribeBranch "I see no item in the ore hold. Time to undock."
                        (case parsedUserInterface |> activeShipTreeEntryFromInventoryWindows |> Maybe.map .uiNode of
                            Nothing ->
                                EndDecisionPath Wait

                            Just activeShipEntry ->
                                EndDecisionPath
                                    (Act
                                        { actionsForCurrentReading =
                                            ( "Rightclick on the ship in the inventory window."
                                            , [ activeShipEntry
                                                    |> clickLocationOnInventoryShipEntry
                                                    |> effectMouseClickAtLocation MouseButtonRight
                                              ]
                                            )
                                        , actionsForFollowingReadings =
                                            [ ( "Click menu entry 'undock'."
                                              , lastContextMenuOrSubmenu
                                                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Undock")
                                                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
                                              )
                                            ]
                                        }
                                    )
                        )

                Just itemInInventory ->
                    DescribeBranch "I see at least one item in the ore hold. Move this to the item hangar."
                        (EndDecisionPath
                            (Act
                                { actionsForCurrentReading =
                                    ( "Drag and drop."
                                    , [ VolatileHostInterface.SimpleDragAndDrop
                                            { startLocation = itemInInventory.totalDisplayRegion |> centerFromDisplayRegion
                                            , endLocation = itemHangar.totalDisplayRegion |> centerFromDisplayRegion
                                            , mouseButton = MouseButtonLeft
                                            }
                                      ]
                                    )
                                , actionsForFollowingReadings = []
                                }
                            )
                        )


lastDockedStationNameFromInfoPanelFromMemoryOrSettings : BotDecisionContext -> Maybe String
lastDockedStationNameFromInfoPanelFromMemoryOrSettings context =
    case context.memory.lastDockedStationNameFromInfoPanel of
        Just stationName ->
            Just stationName

        Nothing ->
            context.settings.lastDockedStationNameFromInfoPanel


decideNextActionWhenInSpace : BotDecisionContext -> SeeUndockingComplete -> DecisionPathNode
decideNextActionWhenInSpace context seeUndockingComplete =
    if seeUndockingComplete.shipUI |> isShipWarpingOrJumping then
        DescribeBranch "I see we are warping." (EndDecisionPath Wait)

    else
        case seeUndockingComplete.shipModulesRows.middle |> List.filter (.isActive >> Maybe.withDefault False >> not) |> List.head of
            Just inactiveModule ->
                DescribeBranch "I see an inactive module in the middle row. Activate it."
                    (EndDecisionPath
                        (Act
                            { actionsForCurrentReading =
                                ( "Click on the module.", [ inactiveModule.uiNode |> clickOnUIElement MouseButtonLeft ] )
                            , actionsForFollowingReadings = []
                            }
                        )
                    )

            Nothing ->
                case context.parsedUserInterface |> oreHoldFillPercent of
                    Nothing ->
                        DescribeBranch "I cannot see the ore hold capacity gauge." (EndDecisionPath Wait)

                    Just fillPercent ->
                        if 99 <= fillPercent then
                            DescribeBranch "The ore hold is full enough. Dock to station."
                                (case context |> lastDockedStationNameFromInfoPanelFromMemoryOrSettings of
                                    Nothing ->
                                        DescribeBranch "At which station should I dock?. I was never docked in a station in this session." (EndDecisionPath Wait)

                                    Just lastDockedStationNameFromInfoPanel ->
                                        dockToStationMatchingNameSeenInInfoPanel
                                            { stationNameFromInfoPanel = lastDockedStationNameFromInfoPanel }
                                            context.parsedUserInterface
                                )

                        else
                            DescribeBranch "The ore hold is not full enough yet. Get more ore."
                                (case context.parsedUserInterface.targets |> List.head of
                                    Nothing ->
                                        DescribeBranch "I see no locked target." (ensureIsAtMiningSiteAndTargetAsteroid context)

                                    Just _ ->
                                        DescribeBranch "I see a locked target."
                                            (case seeUndockingComplete.shipModulesRows.top |> List.filter (.isActive >> Maybe.withDefault False >> not) |> List.head of
                                                -- TODO: Check previous memory reading too for module activity.
                                                Nothing ->
                                                    DescribeBranch "All mining laser modules are active." (EndDecisionPath Wait)

                                                Just inactiveModule ->
                                                    DescribeBranch "I see an inactive mining module. Activate it."
                                                        (EndDecisionPath
                                                            (Act
                                                                { actionsForCurrentReading =
                                                                    ( "Click on the module."
                                                                    , [ inactiveModule.uiNode |> clickOnUIElement MouseButtonLeft ]
                                                                    )
                                                                , actionsForFollowingReadings = []
                                                                }
                                                            )
                                                        )
                                            )
                                )


ensureIsAtMiningSiteAndTargetAsteroid : BotDecisionContext -> DecisionPathNode
ensureIsAtMiningSiteAndTargetAsteroid context =
    case context.parsedUserInterface |> topmostAsteroidFromOverviewWindow of
        Nothing ->
            DescribeBranch "I see no asteroid in the overview. Warp to mining site."
                (warpToMiningSite context.parsedUserInterface)

        Just asteroidInOverview ->
            DescribeBranch
                ("Choosing asteroid '" ++ (asteroidInOverview.objectName |> Maybe.withDefault "Nothing") ++ "'")
                (lockTargetFromOverviewEntryAndEnsureIsInRange (min context.settings.targetingRange context.settings.miningModuleRange) asteroidInOverview)


ensureOreHoldIsSelected : ParsedUserInterface -> DecisionPathNode -> DecisionPathNode
ensureOreHoldIsSelected parsedUserInterface continueIfIsSelected =
    case parsedUserInterface.inventoryWindows |> List.head of
        Nothing ->
            DescribeBranch "I do not see an inventory window. Please open an inventory window." (EndDecisionPath Wait)

        Just inventoryWindow ->
            if inventoryWindow.subCaptionLabelText |> Maybe.map (String.toLower >> String.contains "ore hold") |> Maybe.withDefault False then
                continueIfIsSelected

            else
                DescribeBranch
                    "Ore hold is not selected. Select the ore hold."
                    (case inventoryWindow |> activeShipTreeEntryFromInventoryWindow of
                        Nothing ->
                            DescribeBranch "I do not see the active ship in the inventory." (EndDecisionPath Wait)

                        Just activeShipTreeEntry ->
                            let
                                maybeOreHoldTreeEntry =
                                    activeShipTreeEntry.children
                                        |> List.map EveOnline.ParseUserInterface.unwrapInventoryWindowLeftTreeEntryChild
                                        |> List.filter (.text >> String.toLower >> String.contains "ore hold")
                                        |> List.head
                            in
                            case maybeOreHoldTreeEntry of
                                Nothing ->
                                    DescribeBranch "I do not see the ore hold under the active ship in the inventory."
                                        (case activeShipTreeEntry.toggleBtn of
                                            Nothing ->
                                                DescribeBranch "I do not see the toggle button to expand the active ship tree entry."
                                                    (EndDecisionPath Wait)

                                            Just toggleBtn ->
                                                EndDecisionPath
                                                    (Act
                                                        { actionsForCurrentReading =
                                                            ( "Click the toggle button to expand."
                                                            , [ toggleBtn |> clickOnUIElement MouseButtonLeft ]
                                                            )
                                                        , actionsForFollowingReadings = []
                                                        }
                                                    )
                                        )

                                Just oreHoldTreeEntry ->
                                    EndDecisionPath
                                        (Act
                                            { actionsForCurrentReading =
                                                ( "Click the tree entry representing the ore hold."
                                                , [ oreHoldTreeEntry.uiNode |> clickOnUIElement MouseButtonLeft ]
                                                )
                                            , actionsForFollowingReadings = []
                                            }
                                        )
                    )


lockTargetFromOverviewEntryAndEnsureIsInRange : Int -> OverviewWindowEntry -> DecisionPathNode
lockTargetFromOverviewEntryAndEnsureIsInRange rangeInMeters overviewEntry =
    case overviewEntry.objectDistanceInMeters of
        Ok distanceInMeters ->
            if distanceInMeters <= rangeInMeters then
                DescribeBranch "Object is in range. Lock target."
                    (EndDecisionPath
                        (actStartingWithRightClickOnOverviewEntry overviewEntry
                            [ ( "Click menu entry 'lock'."
                              , lastContextMenuOrSubmenu
                                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "lock")
                                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
                              )
                            ]
                        )
                    )

            else
                DescribeBranch ("Object is not in range (" ++ (distanceInMeters |> String.fromInt) ++ " meters away). Approach.")
                    (EndDecisionPath
                        (actStartingWithRightClickOnOverviewEntry
                            overviewEntry
                            [ ( "Click menu entry 'approach'."
                              , lastContextMenuOrSubmenu
                                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "approach")
                                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
                              )
                            ]
                        )
                    )

        Err error ->
            DescribeBranch ("Failed to read the distance: " ++ error) (EndDecisionPath Wait)


dockToStationMatchingNameSeenInInfoPanel : { stationNameFromInfoPanel : String } -> ParsedUserInterface -> DecisionPathNode
dockToStationMatchingNameSeenInInfoPanel { stationNameFromInfoPanel } =
    dockToStationUsingSurroundingsButtonMenu
        ( "Click on menu entry representing the station '" ++ stationNameFromInfoPanel ++ "'."
        , List.filter (menuEntryMatchesStationNameFromLocationInfoPanel stationNameFromInfoPanel)
            >> List.head
        )


dockToStationUsingSurroundingsButtonMenu :
    ( String, List EveOnline.ParseUserInterface.ContextMenuEntry -> Maybe EveOnline.ParseUserInterface.ContextMenuEntry )
    -> ParsedUserInterface
    -> DecisionPathNode
dockToStationUsingSurroundingsButtonMenu ( describeChooseStation, chooseStationMenuEntry ) =
    useContextMenuOnListSurroundingsButton
        [ ( "Click on menu entry 'stations'."
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "stations")
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
          )
        , ( describeChooseStation
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (.entries >> chooseStationMenuEntry)
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
          )
        , ( "Click on menu entry 'dock'"
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "dock")
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
          )
        ]


warpToMiningSite : ParsedUserInterface -> DecisionPathNode
warpToMiningSite parsedUserInterface =
    parsedUserInterface
        |> useContextMenuOnListSurroundingsButton
            [ ( "Click on menu entry 'asteroid belts'."
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "asteroid belts")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
              )
            , ( "Click on one of the menu entries."
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen
                        (.entries >> listElementAtWrappedIndex (getEntropyIntFromUserInterface parsedUserInterface))
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
              )
            , ( "Click menu entry 'Warp to Within'"
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Warp to Within")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
              )
            , ( "Click menu entry 'Within 0 m'"
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Within 0 m")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft >> List.singleton)
              )
            ]


runAway : BotDecisionContext -> DecisionPathNode
runAway context =
    case context |> lastDockedStationNameFromInfoPanelFromMemoryOrSettings of
        Nothing ->
            dockToRandomStation context.parsedUserInterface

        Just lastDockedStationNameFromInfoPanel ->
            dockToStationMatchingNameSeenInInfoPanel
                { stationNameFromInfoPanel = lastDockedStationNameFromInfoPanel }
                context.parsedUserInterface


dockToRandomStation : ParsedUserInterface -> DecisionPathNode
dockToRandomStation parsedUserInterface =
    dockToStationUsingSurroundingsButtonMenu
        ( "Pick random station.", listElementAtWrappedIndex (getEntropyIntFromUserInterface parsedUserInterface) )
        parsedUserInterface


actStartingWithRightClickOnOverviewEntry :
    OverviewWindowEntry
    -> List ( String, ParsedUserInterface -> Maybe (List VolatileHostInterface.EffectOnWindowStructure) )
    -> EndDecisionPathStructure
actStartingWithRightClickOnOverviewEntry overviewEntry actionsForFollowingReadings =
    Act
        { actionsForCurrentReading =
            ( "Right click on overview entry '" ++ (overviewEntry.objectName |> Maybe.withDefault "") ++ "'."
            , [ overviewEntry.uiNode |> clickOnUIElement MouseButtonRight ]
            )
        , actionsForFollowingReadings = actionsForFollowingReadings
        }


type alias SeeUndockingComplete =
    { shipUI : EveOnline.ParseUserInterface.ShipUI
    , shipModulesRows : EveOnline.ParseUserInterface.ShipUIModulesGroupedIntoRows
    , overviewWindow : EveOnline.ParseUserInterface.OverviewWindow
    }


branchDependingOnDockedOrInSpace :
    DecisionPathNode
    -> (EveOnline.ParseUserInterface.ShipUI -> Maybe DecisionPathNode)
    -> (SeeUndockingComplete -> DecisionPathNode)
    -> ParsedUserInterface
    -> DecisionPathNode
branchDependingOnDockedOrInSpace branchIfDocked branchIfCanSeeShipUI branchIfUndockingComplete parsedUserInterface =
    case parsedUserInterface.shipUI of
        CanNotSeeIt ->
            branchIfDocked

        CanSee shipUI ->
            branchIfCanSeeShipUI shipUI
                |> Maybe.withDefault
                    (case shipUI |> EveOnline.ParseUserInterface.groupShipUIModulesIntoRows of
                        Nothing ->
                            DescribeBranch "Failed to group the ship UI modules into rows." (EndDecisionPath Wait)

                        Just shipModulesRows ->
                            case parsedUserInterface.overviewWindow of
                                CanNotSeeIt ->
                                    DescribeBranch "I see no overview window, wait until undocking completed." (EndDecisionPath Wait)

                                CanSee overviewWindow ->
                                    branchIfUndockingComplete
                                        { shipUI = shipUI, shipModulesRows = shipModulesRows, overviewWindow = overviewWindow }
                    )


useContextMenuOnListSurroundingsButton : List ( String, ParsedUserInterface -> Maybe (List VolatileHostInterface.EffectOnWindowStructure) ) -> ParsedUserInterface -> DecisionPathNode
useContextMenuOnListSurroundingsButton actionsForFollowingReadings parsedUserInterface =
    case parsedUserInterface.infoPanelLocationInfo of
        CanNotSeeIt ->
            DescribeBranch "I cannot see the location info panel." (EndDecisionPath Wait)

        CanSee infoPanelLocationInfo ->
            EndDecisionPath
                (Act
                    { actionsForCurrentReading =
                        ( "Click on surroundings button."
                        , [ infoPanelLocationInfo.listSurroundingsButton |> clickOnUIElement MouseButtonLeft ]
                        )
                    , actionsForFollowingReadings = actionsForFollowingReadings
                    }
                )


initState : State
initState =
    EveOnline.BotFramework.initState
        { programState = Nothing
        , botMemory = { lastDockedStationNameFromInfoPanel = Nothing }
        }


processEvent : InterfaceToHost.BotEvent -> State -> ( State, InterfaceToHost.BotResponse )
processEvent =
    EveOnline.BotFramework.processEvent processEveOnlineBotEvent


processEveOnlineBotEvent :
    EveOnline.BotFramework.BotEventContext
    -> EveOnline.BotFramework.BotEvent
    -> BotState
    -> ( BotState, EveOnline.BotFramework.BotEventResponse )
processEveOnlineBotEvent eventContext event stateBefore =
    case parseSettingsFromString defaultBotSettings (eventContext.appSettings |> Maybe.withDefault "") of
        Err parseSettingsError ->
            ( stateBefore
            , EveOnline.BotFramework.FinishSession { statusDescriptionText = "Failed to parse bot settings: " ++ parseSettingsError }
            )

        Ok settings ->
            processEveOnlineBotEventWithSettings settings event stateBefore


processEveOnlineBotEventWithSettings :
    BotSettings
    -> EveOnline.BotFramework.BotEvent
    -> BotState
    -> ( BotState, EveOnline.BotFramework.BotEventResponse )
processEveOnlineBotEventWithSettings botSettings event stateBefore =
    case event of
        EveOnline.BotFramework.MemoryReadingCompleted parsedUserInterface ->
            let
                botMemory =
                    stateBefore.botMemory |> integrateCurrentReadingsIntoBotMemory parsedUserInterface

                programStateIfEvalDecisionTreeNew =
                    let
                        originalDecision =
                            decideNextAction
                                { settings = botSettings, memory = botMemory, parsedUserInterface = parsedUserInterface }

                        originalRemainingActions =
                            case unpackToDecisionStagesDescriptionsAndLeaf originalDecision |> Tuple.second of
                                Wait ->
                                    []

                                Act act ->
                                    ( act.actionsForCurrentReading |> Tuple.first
                                    , always (act.actionsForCurrentReading |> Tuple.second |> Just)
                                    )
                                        :: act.actionsForFollowingReadings
                    in
                    { originalDecision = originalDecision, remainingActions = originalRemainingActions }

                programStateToContinue =
                    stateBefore.programState
                        |> Maybe.andThen
                            (\previousProgramState ->
                                if 0 < (previousProgramState.remainingActions |> List.length) then
                                    Just previousProgramState

                                else
                                    Nothing
                            )
                        |> Maybe.withDefault programStateIfEvalDecisionTreeNew

                ( originalDecisionStagesDescriptions, _ ) =
                    unpackToDecisionStagesDescriptionsAndLeaf programStateToContinue.originalDecision

                ( currentStepDescription, effectsOnGameClientWindow, programState ) =
                    case programStateToContinue.remainingActions of
                        [] ->
                            ( "Wait", [], Nothing )

                        ( nextActionDescription, nextActionEffectFromUserInterface ) :: remainingActions ->
                            case parsedUserInterface |> nextActionEffectFromUserInterface of
                                Nothing ->
                                    ( "Failed step: " ++ nextActionDescription, [], Nothing )

                                Just effects ->
                                    ( nextActionDescription
                                    , effects
                                    , Just { programStateToContinue | remainingActions = remainingActions }
                                    )

                effectsRequests =
                    effectsOnGameClientWindow |> List.map EveOnline.BotFramework.EffectOnGameClientWindow

                describeActivity =
                    (originalDecisionStagesDescriptions ++ [ currentStepDescription ])
                        |> List.indexedMap
                            (\decisionLevel -> (++) (("+" |> List.repeat (decisionLevel + 1) |> String.join "") ++ " "))
                        |> String.join "\n"

                statusMessage =
                    [ parsedUserInterface |> describeUserInterfaceForMonitoring, describeActivity ]
                        |> String.join "\n"
            in
            ( { stateBefore | botMemory = botMemory, programState = programState }
            , EveOnline.BotFramework.ContinueSession
                { effects = effectsRequests
                , millisecondsToNextReadingFromGame = botSettings.botStepDelayMilliseconds
                , statusDescriptionText = statusMessage
                }
            )


describeUserInterfaceForMonitoring : ParsedUserInterface -> String
describeUserInterfaceForMonitoring parsedUserInterface =
    let
        describeShip =
            case parsedUserInterface.shipUI of
                CanSee shipUI ->
                    "I am in space, shield HP at " ++ (shipUI.hitpointsPercent.shield |> String.fromInt) ++ "%."

                CanNotSeeIt ->
                    case parsedUserInterface.infoPanelLocationInfo |> maybeVisibleAndThen .expandedContent |> maybeNothingFromCanNotSeeIt |> Maybe.andThen .currentStationName of
                        Just stationName ->
                            "I am docked at '" ++ stationName ++ "'."

                        Nothing ->
                            "I cannot see if I am docked or in space. Please set up game client first."

        describeOreHold =
            "Ore hold filled " ++ (parsedUserInterface |> oreHoldFillPercent |> Maybe.map String.fromInt |> Maybe.withDefault "Unknown") ++ "%."
    in
    [ describeShip, describeOreHold ] |> String.join " "


integrateCurrentReadingsIntoBotMemory : ParsedUserInterface -> BotMemory -> BotMemory
integrateCurrentReadingsIntoBotMemory currentReading botMemoryBefore =
    let
        currentStationNameFromInfoPanel =
            currentReading.infoPanelLocationInfo
                |> maybeVisibleAndThen .expandedContent
                |> maybeNothingFromCanNotSeeIt
                |> Maybe.andThen .currentStationName
    in
    { lastDockedStationNameFromInfoPanel =
        [ currentStationNameFromInfoPanel, botMemoryBefore.lastDockedStationNameFromInfoPanel ]
            |> List.filterMap identity
            |> List.head
    }


unpackToDecisionStagesDescriptionsAndLeaf : DecisionPathNode -> ( List String, EndDecisionPathStructure )
unpackToDecisionStagesDescriptionsAndLeaf node =
    case node of
        EndDecisionPath leaf ->
            ( [], leaf )

        DescribeBranch branchDescription childNode ->
            let
                ( childDecisionsDescriptions, leaf ) =
                    unpackToDecisionStagesDescriptionsAndLeaf childNode
            in
            ( branchDescription :: childDecisionsDescriptions, leaf )


activeShipTreeEntryFromInventoryWindows : ParsedUserInterface -> Maybe EveOnline.ParseUserInterface.InventoryWindowLeftTreeEntry
activeShipTreeEntryFromInventoryWindows =
    .inventoryWindows
        >> List.head
        >> Maybe.andThen activeShipTreeEntryFromInventoryWindow


activeShipTreeEntryFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe EveOnline.ParseUserInterface.InventoryWindowLeftTreeEntry
activeShipTreeEntryFromInventoryWindow =
    .leftTreeEntries
        -- Assume upmost entry is active ship.
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


{-| Returns the menu entry containing the string from the parameter `textToSearch`.
If there are multiple such entries, these are sorted by the length of their text, minus whitespaces in the beginning and the end.
The one with the shortest text is returned.
-}
menuEntryContainingTextIgnoringCase : String -> EveOnline.ParseUserInterface.ContextMenu -> Maybe EveOnline.ParseUserInterface.ContextMenuEntry
menuEntryContainingTextIgnoringCase textToSearch =
    .entries
        >> List.filter (.text >> String.toLower >> String.contains (textToSearch |> String.toLower))
        >> List.sortBy (.text >> String.trim >> String.length)
        >> List.head


{-| The names are at least sometimes displayed different: 'Moon 7' can become 'M7'
-}
menuEntryMatchesStationNameFromLocationInfoPanel : String -> EveOnline.ParseUserInterface.ContextMenuEntry -> Bool
menuEntryMatchesStationNameFromLocationInfoPanel stationNameFromInfoPanel menuEntry =
    (stationNameFromInfoPanel |> String.toLower |> String.replace "moon " "m")
        == (menuEntry.text |> String.trim |> String.toLower)


lastContextMenuOrSubmenu : ParsedUserInterface -> Maybe EveOnline.ParseUserInterface.ContextMenu
lastContextMenuOrSubmenu =
    .contextMenus >> List.head


topmostAsteroidFromOverviewWindow : ParsedUserInterface -> Maybe OverviewWindowEntry
topmostAsteroidFromOverviewWindow =
    overviewWindowEntriesRepresentingAsteroids
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


overviewWindowEntriesRepresentingAsteroids : ParsedUserInterface -> List OverviewWindowEntry
overviewWindowEntriesRepresentingAsteroids =
    .overviewWindow
        >> maybeNothingFromCanNotSeeIt
        >> Maybe.map (.entries >> List.filter overviewWindowEntryRepresentsAnAsteroid)
        >> Maybe.withDefault []


overviewWindowEntryRepresentsAnAsteroid : OverviewWindowEntry -> Bool
overviewWindowEntryRepresentsAnAsteroid entry =
    (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "asteroid"))
        && (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "belt") |> not)


oreHoldFillPercent : ParsedUserInterface -> Maybe Int
oreHoldFillPercent =
    .inventoryWindows
        >> List.head
        >> Maybe.andThen .selectedContainerCapacityGauge
        >> Maybe.andThen Result.toMaybe
        >> Maybe.andThen
            (\capacity -> capacity.maximum |> Maybe.map (\maximum -> capacity.used * 100 // maximum))


inventoryWindowSelectedContainerFirstItem : ParsedUserInterface -> Maybe UIElement
inventoryWindowSelectedContainerFirstItem =
    .inventoryWindows
        >> List.head
        >> Maybe.andThen .selectedContainerInventory
        >> Maybe.andThen .itemsView
        >> Maybe.map
            (\itemsView ->
                case itemsView of
                    EveOnline.ParseUserInterface.InventoryItemsListView { items } ->
                        items

                    EveOnline.ParseUserInterface.InventoryItemsNotListView { items } ->
                        items
            )
        >> Maybe.andThen List.head


inventoryWindowItemHangar : ParsedUserInterface -> Maybe UIElement
inventoryWindowItemHangar =
    .inventoryWindows
        >> List.head
        >> Maybe.map .leftTreeEntries
        >> Maybe.andThen (List.filter (.text >> String.toLower >> String.contains "item hangar") >> List.head)
        >> Maybe.map .uiNode


clickOnUIElement : MouseButton -> UIElement -> VolatileHostInterface.EffectOnWindowStructure
clickOnUIElement mouseButton uiElement =
    effectMouseClickAtLocation mouseButton (uiElement.totalDisplayRegion |> centerFromDisplayRegion)


{-| The region of a ship entry in the inventory window can contain child nodes (e.g. 'Ore Hold').
For this reason, we don't click on the center but stay close to the top.
-}
clickLocationOnInventoryShipEntry : UIElement -> VolatileHostInterface.Location2d
clickLocationOnInventoryShipEntry uiElement =
    { x = uiElement.totalDisplayRegion.x + uiElement.totalDisplayRegion.width // 2
    , y = uiElement.totalDisplayRegion.y + 7
    }


isShipWarpingOrJumping : EveOnline.ParseUserInterface.ShipUI -> Bool
isShipWarpingOrJumping =
    .indication
        >> maybeNothingFromCanNotSeeIt
        >> Maybe.andThen (.maneuverType >> maybeNothingFromCanNotSeeIt)
        >> Maybe.map
            (\maneuverType ->
                [ EveOnline.ParseUserInterface.ManeuverWarp, EveOnline.ParseUserInterface.ManeuverJump ]
                    |> List.member maneuverType
            )
        -- If the ship is just floating in space, there might be no indication displayed.
        >> Maybe.withDefault False


listElementAtWrappedIndex : Int -> List element -> Maybe element
listElementAtWrappedIndex indexToWrap list =
    if (list |> List.length) < 1 then
        Nothing

    else
        list |> List.drop (indexToWrap |> modBy (list |> List.length)) |> List.head


parseBotSettingInt : (Int -> BotSettings -> BotSettings) -> String -> Result String (BotSettings -> BotSettings)
parseBotSettingInt integrateInt argumentAsString =
    case argumentAsString |> String.toInt of
        Nothing ->
            Err ("Failed to parse '" ++ argumentAsString ++ "' as integer.")

        Just int ->
            Ok (integrateInt int)


parseSettingsFromString : BotSettings -> String -> Result String BotSettings
parseSettingsFromString settingsBefore settingsString =
    let
        assignments =
            settingsString |> String.split ","

        assignmentFunctionResults =
            assignments
                |> List.map String.trim
                |> List.filter (String.isEmpty >> not)
                |> List.map
                    (\assignment ->
                        case assignment |> String.split "=" |> List.map String.trim of
                            [ settingName, assignedValue ] ->
                                case parseBotSettingsNames |> Dict.get settingName of
                                    Nothing ->
                                        Err ("Unknown setting name '" ++ settingName ++ "'.")

                                    Just parseFunction ->
                                        parseFunction assignedValue
                                            |> Result.mapError (\parseError -> "Failed to parse value for setting '" ++ settingName ++ "': " ++ parseError)

                            _ ->
                                Err ("Failed to parse assignment '" ++ assignment ++ "'.")
                    )
    in
    assignmentFunctionResults
        |> Result.Extra.combine
        |> Result.map
            (\assignmentFunctions ->
                assignmentFunctions
                    |> List.foldl (\assignmentFunction previousSettings -> assignmentFunction previousSettings)
                        settingsBefore
            )