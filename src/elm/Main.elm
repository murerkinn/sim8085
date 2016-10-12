port module Main exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.App as App
import Html.Events exposing (..)

import Array exposing (..)
import Bitwise exposing (..)
import Char exposing (..)
import String exposing (..)

type ProgramState
  = Idle
  | Loaded
  | Running
  | Paused

-- APP
main : Program Never
main =
  App.program { init = init, view = view, update = update, subscriptions = subscriptions }

-- MODEL
type alias Model =
  { code: String
  , error: Maybe AssemblerError
  , assembled: Array AssembledCode
  , breakpoints: List Int
  , loadAddr: Int
  , programState: ProgramState
  , accumulator: Int
  , registers: Register
  , stackPtr: Int
  , programCounter: Int
  , statePtr: Maybe Int
  , memory: Array Int
  , memoryStart: Int
  , memoryStartLarge: Int
  , memoryStartSmall: Int
  , flags: Flags
  , activeFile: String
  , openFiles: List File
  }

init : ( Model, Cmd Msg )
init =
  ( { code = initialCode
    , error = Nothing
    , assembled = Array.empty
    , breakpoints = []
    , loadAddr = 2048
    , programState = Idle
    , accumulator = 0
    , registers = registers
    , stackPtr = 0
    , programCounter = 0
    , statePtr = Nothing
    , memory = Array.repeat 65536 0
    , memoryStart = 0
    , memoryStartLarge = 0
    , memoryStartSmall = 0
    , flags = flags
    , activeFile = "main.asm"
    , openFiles = [ File "main.asm" "" ]
    }, Cmd.none )

initialCode =
  """;<Program title>

jmp start

;data

;code
start: nop


hlt"""

type alias RegisterField =
  { high: Int, low: Int, editing: Bool }

type alias Register =
  { bc: RegisterField
  , de: RegisterField
  , hl: RegisterField
  }

type alias Flags =
  { s: Bool
  , z: Bool
  , ac: Bool
  , p: Bool
  , c: Bool
  }

type alias File =
  { name: String
  , code: String
  }

registers : Register
registers =
  { bc = { high = 0, low = 0, editing = False }
  , de = { high = 0, low = 0, editing = False }
  , hl = { high = 0, low = 0, editing = False }
  }

flags : Flags
flags =
  { s = False
  , z = False
  , ac = False
  , p = False
  , c = False
  }




-- UPDATE

type Msg
  = Run
  | RunOne
  | Load
  | Stop
  | UpdateCode String
  | UpdateAssembledCode (Array AssembledCode)
  | UpdateAssemblerError AssemblerError
  | UpdateState ExternalState
  | UpdateMemory (Array Int)
  | UpdateProgramState String
  | PreviousMemoryPage
  | NextMemoryPage
  | ChangeMemoryStart String
  | ChangeMemoryStartSmall String
  | UpdateBreakpoints BreakPointAction
  | EditRegister String
  | SaveRegister String String
  | StopEditRegister String

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
  case msg of
    Run -> (model, run { assembled = (Array.map (.data) model.assembled), state = createExternalStateFromModel model })
    RunOne ->
      if model.programState == Loaded
      then
        ({ model | programState = Paused, programCounter = model.loadAddr }
        , debug { state = (let s = createExternalStateFromModel model in { s | pc = model.loadAddr })
                , nextLine = case findLineAtPC (model.programCounter) model.assembled model.memory of
                              Nothing -> model.programCounter - model.loadAddr
                              Just l -> l }
        )
      else
      (
        { model | programState = Running }
      , runOne { state = createExternalStateFromModel model }
      )
    Load -> (model, load { offset = model.loadAddr, code = model.code })
    UpdateProgramState ps ->
      ({ model | programState =
                  case ps of
                    "Loaded" -> Loaded
                    "Idle" -> Idle
                    "Running" -> Idle
                    "Paused" -> Paused
                    _ -> Idle }
        , Cmd.none)
    UpdateState state ->
      ({ model | accumulator = updateOnLoaded state.programState state.a model.accumulator
               , registers = updateOnLoaded state.programState (readRegistersFromExternalState model.registers state) model.registers
               , flags = updateOnLoaded state.programState (readFlagsFromExternalState model.flags state) model.flags
               , stackPtr = updateOnLoaded state.programState state.sp model.stackPtr
               , programCounter = state.pc
               , statePtr = state.ptr
               , memory = state.memory }
      , if model.programState == Paused
        then nextLine (case findLineAtPC (state.pc) model.assembled model.memory of
                        Nothing -> model.programCounter - model.loadAddr
                        Just l -> l)
        else Cmd.none )
    UpdateMemory memory -> ({model | memory = memory}, Cmd.none)
    _ -> ( updateHelper msg model, Cmd.none )

updateHelper : Msg -> Model -> Model
updateHelper msg model =
  case msg of
    UpdateCode code -> { model | code = code }
    UpdateAssembledCode code ->
      { model | assembled = code
              , error = Nothing
              , memory = loadCode model.memory code model.loadAddr }
    PreviousMemoryPage -> { model | memoryStart = if model.memoryStart == 0 then 0 else model.memoryStart - 256 }
    NextMemoryPage -> { model | memoryStart = if model.memoryStart == 65536 - 128 then model.memoryStart else model.memoryStart + 256 }
    ChangeMemoryStart v ->
      let
        n = Result.withDefault 0 (String.toInt v)
      in
        { model | memoryStartLarge = n
                , memoryStart = n + model.memoryStartSmall }
    ChangeMemoryStartSmall v ->
      let
        n = Result.withDefault 0 (String.toInt v)
      in
        { model | memoryStartSmall = n
                , memoryStart = n + model.memoryStartLarge }
    UpdateAssemblerError e -> { model | error = Just e, assembled = Array.empty }
    UpdateBreakpoints ba ->
      { model | breakpoints = if ba.action == "add"
                              then ba.line :: model.breakpoints
                              else List.filter (\b -> b /= ba.line) model.breakpoints }
    Stop -> { model | programState = Idle }
    EditRegister name ->
      { model | registers =
                  case name of
                    "bc" -> { registers | bc = setRegisterEdit model.registers.bc True }
                    "de" -> { registers | de = setRegisterEdit model.registers.de True }
                    "hl" -> { registers | hl = setRegisterEdit model.registers.hl True }
                    _ -> model.registers
      }
    StopEditRegister name ->
      { model | registers =
                  case name of
                    "bc" -> { registers | bc = setRegisterEdit model.registers.bc False }
                    "de" -> { registers | de = setRegisterEdit model.registers.de False }
                    "hl" -> { registers | hl = setRegisterEdit model.registers.hl False }
                    _ -> model.registers
      }
    SaveRegister name value ->
      { model | registers =
                  case name of
                    "bc" -> { registers | bc = saveRegisterEdit model.registers.bc value }
                    "de" -> { registers | de = saveRegisterEdit model.registers.de value }
                    "hl" -> { registers | hl = saveRegisterEdit model.registers.hl value }
                    _ -> model.registers
      }
    _ -> model

updateOnLoaded programState n o =
  if programState == "Loaded" then o else n

loadCode memory code loadAddr =
  let
    codeLength = Array.length code
    startOfMemory = Array.toList (Array.slice 0 (loadAddr) memory)
    opcodes = Array.toList (Array.map (.data) code)
    restOfMemory = Array.toList (Array.slice (loadAddr + codeLength) 65536 memory)
  in
    Array.fromList (List.append (List.append startOfMemory opcodes) restOfMemory)

setRegisterEdit register isEditing =
  { high = register.high, low = register.low, editing = isEditing }

saveRegisterEdit register value =
  let
    v = Result.withDefault 0 (String.toInt value)
  in
    { high = (v `shiftRight` 8) `and` 0xff, low = v `and` 0xff, editing = register.editing }

findLineAtPC pc assembled memory =
  let
    opcode = Array.get pc memory
  in
    case opcode of
      Nothing -> Nothing
      Just code ->
        case Array.get 0 (Array.filter (\c -> c.data == code) assembled) of
          Nothing -> Nothing
          Just a -> Just a.location.start.line

readRegistersFromExternalState registers state =
  { bc = { high = state.b, low = state.c, editing = registers.bc.editing }
  , de = { high = state.d, low = state.e, editing = registers.de.editing }
  , hl = { high = state.h, low = state.l, editing = registers.hl.editing }
  }

readFlagsFromExternalState flags state =
  { s = state.flags.s
  , z = state.flags.z
  , ac = state.flags.ac
  , p = state.flags.p
  , c = state.flags.cy
  }

createExternalStateFromModel model =
  { a = model.accumulator
  , b = model.registers.bc.high
  , c = model.registers.bc.low
  , d = model.registers.de.high
  , e = model.registers.de.low
  , h = model.registers.hl.high
  , l = model.registers.hl.low
  , sp = model.stackPtr
  , pc = model.programCounter
  , flags =
    { z = model.flags.s
    , s = model.flags.z
    , p = model.flags.p
    , cy = model.flags.c
    , ac = model.flags.ac
    }
  , memory = model.memory
  , ptr = model.statePtr
  , programState = getProgramState model.programState
  }

getProgramState programState =
  case programState of
    Idle -> "Idle"
    Loaded -> "Loaded"
    Running -> "Running"
    Paused -> "Paused"





-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch
    [ code UpdateCode
    , assembled UpdateAssembledCode
    , state UpdateState
    , memory UpdateMemory
    , programState UpdateProgramState
    , error UpdateAssemblerError
    , breakpoints UpdateBreakpoints
    ]


-- VIEW
-- Html is defined as: elem [ attribs ][ children ]
-- CSS can be applied via class names or inline style attrib

view : Model -> Html Msg
view model =
  div [ class "work-area" ] [
      div [ class "row" ] [
        div [ class "col-md-2" ] [
            div [] [
              h3 [] [ text "Registers" ]
            , table [ class "table table-striped" ] [
                tbody [] (showRegisters model.accumulator model.flags model.registers model.stackPtr model.programCounter)
              ]
            ]
          , div [] [
              h3 [] [ text "Flags" ]
            , table [ class "table table-striped" ] [ tbody [] (showFlags model.flags) ]
            ]
        ]
        , div [ class "col-md-5 coding-area" ] [
              div [ class "coding-area__toolbar"] [
                  div [ class "btn-toolbar coding-area__btn-toolbar" ] [
                      div [ class "btn-group" ] [
                          toolbarButton (model.programState /= Idle) "success" Load "Assemble and Load Program" "save"
                        , toolbarButton (model.programState == Idle) "warning" Stop "Stop program and return to editing" "stop"
                        , toolbarButton (model.programState /= Loaded && model.programState /= Paused) "success" Run "Run Program" "fast-forward"
                        , toolbarButton (model.programState /= Loaded && model.programState /= Paused)
                                        "success" RunOne "Run one instruction" "step-forward"
                      ]
                    , div [ class "btn-group" ] [
                        toolbarButton (model.programState == Idle) "danger" Run "Reset Everything" "refresh"
                      ]
                  ]
                , div [ class "pull-right" ] [
                      text "Load at "
                    , text "0x0800"
                    , text <| toString <| Array.get model.loadAddr model.memory
                  ]
              ]
            , ul [ class "nav nav-tabs" ]
                 (List.append (List.map (showOpenFileTabs model.activeFile) model.openFiles) [tabAddButton])
            , div [ class "coding-area__editor-container" ] [
                  textarea [ id "coding-area__editor", value model.code ] []
              ]
          ]
        , div [ class "col-md-4" ] [
              div [ class "" ] [ showMemory model model.memory model.memoryStart model.memoryStartSmall ]
          ]
      ]
    , div [ class "row" ] [
          div [ class "col-md-7" ] [
              div [ class "panel panel-default" ] [
                  div [ class "panel-heading" ] [ h3 [ class "panel-title" ] [ text "Assembler Output" ] ]
                , div [ class "panel-body" ] [
                      case model.error of
                        Nothing -> (showAssembled model.assembled model.code)
                        Just error -> showAssemblerError error model.code
                  ]
              ]
          ]
      ]
  ]


toolbarButton isDisabled type' msg tooltip icon =
    button [ class ("btn  btn-sm btn-" ++ type'), onClick msg, title tooltip, disabled isDisabled ] [
        span [ class ("glyphicon glyphicon-" ++ icon) ] []
    ]

tabAddButton =
    li [ class "" ] [
       button [ class "btn" ] [ span [ class "glyphicon glyphicon-plus" ] [] ]
    ]

showAssemblerError error code =
  text ("Line " ++ (toString error.line) ++ ", Column " ++ (toString error.column) ++ ": " ++ error.msg)

zipAssembledSource assembled source =
  let
    sourceLines = Array.fromList (String.split "\n" source)
    findAssembled ln =
      Array.map (\a -> { data = a.data, kind = a.kind }) (Array.filter (\c -> (c.location.start.line - 1) == ln) assembled)
  in
    Array.indexedMap (\i s -> (findAssembled i, s)) sourceLines

showAssembled assembled source =
  let
    ls = zipAssembledSource assembled source
    showSingleLine l =
      tr [] [
          td [] [ text  <| showCode (fst l) ]
        , td [] [ text (snd l) ]
      ]
  in
    table [ class "table" ] [ tbody [] (Array.toList (Array.map showSingleLine ls)) ]

showCode codes =
  let
    code = Array.map (.data) (Array.filter (\c -> c.kind == "code") codes)
    data = Array.map (.data) (Array.filter (\c -> c.kind /= "code") codes)
  in
    (String.toUpper <| toRadix 16 <| (Maybe.withDefault 0 (Array.get 0 code))) ++ "  " ++
      (Array.foldr (\a b -> (toString a) ++ " " ++ b) "" data)

showRegister name rid { high, low, editing } =
  tr [] [
     th [ scope "row" ] [ text name ]
   , td [] [ span [] [ text "0x" ] ]
   , td [ onDoubleClick (EditRegister rid), hidden editing ] [
        span [] [ text <| String.toUpper <| toByte high ]
      , span [] [ text <| String.toUpper <| toByte low ]
    ]
   , td [ onDoubleClick (EditRegister rid), hidden (not editing) ] [
        input [ onInput (SaveRegister rid), onBlur (StopEditRegister rid), value (toString <| (high `shiftLeft` 8) + low) ] []
    ]
  ]

getFlagByte flags =
  Array.foldl (\a b -> a + b) 0
              (Array.indexedMap (\i f -> (2^i) * (if f then 1 else 0))
                                (Array.fromList [flags.c, True, flags.p, False, flags.ac, False, flags.z, flags.s]))

showRegisters accumulator flags registers stackPtr programCounter =
  [ showRegister "A/PSW" "a" { high = accumulator, low = getFlagByte flags, editing = False }
  , showRegister "BC" "bc" registers.bc
  , showRegister "DE" "de" registers.de
  , showRegister "HL" "hl" registers.hl
  , showRegister "SP" "sp" { high = (stackPtr `shiftRight` 8) `and` 0xff, low = stackPtr `and` 0xff, editing = False }
  , showRegister "PC" "pc" { high = (programCounter `shiftRight` 8) `and` 0xff, low = programCounter `and` 0xff, editing = False }
  ]

showFlag : String -> Bool -> Html msg
showFlag name value =
  tr [] [
     th [ scope "row" ] [ text name ]
   , td [] [ text <| toString <| (if value then 1 else 0) ]
  ]

showFlags : Flags -> List (Html msg)
showFlags flags =
  [ showFlag "Z" flags.z
  , showFlag "S" flags.s
  , showFlag "P" flags.p
  , showFlag "C" flags.c
  , showFlag "AC" flags.ac
  ]


showOpenFileTabs : String -> File -> Html msg
showOpenFileTabs activeFileName { name, code } =
    li [ class (if activeFileName == name then "active" else "") ] [
       a [ href "#" ] [ text name ]
    ]

showMemory model memory memoryStart memoryStartSmall =
  div [ class "memory-view" ] [
      h3 [] [ text "Memory View" ]
    , table [ class "table memory-view__cells" ] [
          thead [] (td [] [] :: (List.map (\c -> td [] [ text <| (String.toUpper (toRadix 16 c)) ]) [0..15]))
        , tbody [] (Array.toList (showMemoryCells model memoryStart (Array.slice memoryStart (memoryStart + 256) memory)))
      ]
    , div [ class "memory-view___paginator row" ] [
          div [ class "col-sm-6" ] [
              span [ style [("font-size", "0.8em")]] [ text "Start Address at: 0x " ]
            , select [ onInput ChangeMemoryStart ] (List.map (\n -> option [ value <| toString <| n ] [ text (String.toUpper (toRadix 16 n)) ]) (List.map (\n -> n * 4352) [0..15]))
          ]
        , div [ class "col-md-6" ] [
              input [ type' "range"
                    , Html.Attributes.min "0"
                    , Html.Attributes.max "4096"
                    , step "256"
                    , onInput ChangeMemoryStartSmall
                    , value (toString memoryStartSmall)
                    ] []
          ]
      ]
  ]

isEven n = n % 2 == 0

isOdd n = n % 2 /= 0

chunk : Int -> List a -> List (List a)
chunk k xs =
  let len = List.length xs
  in  if len > k
      then List.take k xs :: chunk k (List.drop k xs)
      else [xs]

memoryCellHighlightType model addr cell =
  if addr >= model.loadAddr && addr < (model.loadAddr + Array.length model.assembled)
  then "highlight"
  else ""

showMemoryCell : Model -> Int -> Int -> Int -> Html Msg
showMemoryCell model start col cell =
  let
    addr = start + col
  in
    td [ class ("memory-view__cell_" ++ (memoryCellHighlightType model addr cell)), title (toWord addr) ] [
       text <| String.toUpper <| toByte <| cell
    ]

showMemoryCellRow : Model -> Int -> Int -> List Int -> Html Msg
showMemoryCellRow model start i cells = tr [] ( (th [ scope "row" ] [ text <| String.toUpper <| toThreeBytes ((start//16) + i) ]) :: (List.indexedMap (showMemoryCell model (start + i * 16)) cells))

showMemoryCells : Model -> Int-> Array Int -> Array (Html Msg)
showMemoryCells model start cells =
  Array.indexedMap (showMemoryCellRow model start) (Array.fromList (chunk 16 (Array.toList cells)))

showScalePoint value =
  li [] [ text <| toString <| value ]

toRadix : Int -> Int -> String
toRadix r n =
  let
    getChr c = if c < 10 then toString c else String.fromChar <| Char.fromCode (87+c)
    getStr b = if n < b then getChr n else (toRadix r (n//b)) ++  (getChr (n%b))
  in
    case (r>=2 && r<=16) of
      True -> getStr r
      False -> toString n

toWord n =
  if n < 16
    then ("000" ++ toRadix 16 n)
    else if n < 256 then ("00" ++ toRadix 16 n)
    else if n < 4096 then ("0" ++ toRadix 16 n) else toRadix 16 n

toThreeBytes n =
  if n < 16
    then ("00" ++ toRadix 16 n)
    else if n < 256 then ("0" ++ toRadix 16 n) else (toRadix 16 n)

toByte n =
  if n < 16
    then ("0" ++ (toRadix 16 n))
    else (toRadix 16 n)

-- Ports

type alias ExternalState =
  { a: Int
  , b: Int
  , c: Int
  , d: Int
  , e: Int
  , h: Int
  , l: Int
  , sp: Int
  , pc: Int
  , flags:
    { z: Bool
    , s: Bool
    , p: Bool
    , cy: Bool
    , ac: Bool
    }
  , memory: Array Int
  , ptr: Maybe Int
  , programState: String
  }

type alias CodeLocation =
  { offset: Int
  , line: Int
  , column: Int
  }

type alias AssembledCode =
  { data: Int
  , kind: String
  , location: { start: CodeLocation, end: CodeLocation }
  }

type alias AssemblerError =
  { name: String
  , msg: String
  , line: Int
  , column: Int
  }

type alias BreakPointAction =
  { action: String
  , line: Int
  }

port load : { offset: Int, code: String } -> Cmd msg
port run : { assembled: Array Int, state: ExternalState } -> Cmd msg
port runOne : { state: ExternalState } -> Cmd msg
port debug : { state: ExternalState, nextLine: Int } -> Cmd msg
port nextLine : Int -> Cmd msg

port code : (String -> msg) -> Sub msg
port assembled : (Array AssembledCode -> msg) -> Sub msg
port error : (AssemblerError -> msg) -> Sub msg
port state : (ExternalState -> msg) -> Sub msg
port memory : (Array Int -> msg) -> Sub msg
port programState : (String -> msg) -> Sub msg
port breakpoints : (BreakPointAction -> msg) -> Sub msg