port module Main exposing (main)

{-| The ClaudeView viewer.

It knows almost nothing: on every SSE ping it re-fetches `/content` (the list of
tabs, already rendered to HTML by the server, plus the directories being watched)
and shows the tab the server marks as focused — the most recently modified one.
Clicking a tab pins it until the next content change.

Tabs are named `<session>~<doc>` (session is `<repo>~<branch>`), so the viewer
folds them into one split-button per session: the button jumps to that session's
newest document, and a dropdown reaches the older ones. The part before the last
`~` is the group key, matched case-insensitively; a name with no `~` falls back to
the older rule (the segment before the first `-`) so pre-`~` tabs still group.

A slim header shows what the server is watching, the document on screen, and
whether the live connection is up, so an empty screen still tells you where to look.

-}

import Browser
import Dict
import Html exposing (Html, button, div, node, span, text)
import Html.Attributes exposing (class, classList, property)
import Html.Events exposing (onClick)
import Http
import Json.Decode as D
import Json.Encode as E
import Task
import Time



-- PORTS


port sseMessage : (String -> msg) -> Sub msg


port sseStatus : (Bool -> msg) -> Sub msg


port setTheme : String -> Cmd msg



-- MODEL


type alias Tab =
    { name : String, html : String, mtime : Int }


type alias Model =
    { tabs : List Tab
    , focus : Maybe String
    , watching : List String
    , connected : Bool
    , theme : String
    , openGroup : Maybe String -- the group whose dropdown is open, if any
    , now : Int -- POSIX seconds, so the dropdown can say "2h ago"
    }


{-| The flag is the theme JS resolved before first paint ("light" or "dark").
-}
init : String -> ( Model, Cmd Msg )
init theme =
    ( { tabs = [], focus = Nothing, watching = [], connected = False, theme = theme, openGroup = Nothing, now = 0 }
    , Cmd.batch [ fetchContent, Task.perform Tick Time.now ]
    )



-- UPDATE


type alias Content =
    { tabs : List Tab, focus : Maybe String, watching : List String }


type Msg
    = Ping String
    | Status Bool
    | GotContent (Result Http.Error Content)
    | Focus String
    | ToggleGroup String
    | CloseMenu
    | Tick Time.Posix
    | ToggleTheme


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Ping _ ->
            ( model, fetchContent )

        Status connected ->
            ( { model | connected = connected }, Cmd.none )

        GotContent (Ok c) ->
            ( { model | tabs = c.tabs, focus = c.focus, watching = c.watching }, Cmd.none )

        GotContent (Err _) ->
            ( model, Cmd.none )

        Focus name ->
            -- Selecting a document (button or dropdown item) also closes the menu.
            ( { model | focus = Just name, openGroup = Nothing }, Cmd.none )

        ToggleGroup key ->
            ( { model | openGroup = toggle key model.openGroup }, Cmd.none )

        CloseMenu ->
            ( { model | openGroup = Nothing }, Cmd.none )

        Tick posix ->
            ( { model | now = Time.posixToMillis posix // 1000 }, Cmd.none )

        ToggleTheme ->
            let
                next =
                    if model.theme == "dark" then
                        "light"

                    else
                        "dark"
            in
            ( { model | theme = next }, setTheme next )


toggle : String -> Maybe String -> Maybe String
toggle key open =
    if open == Just key then
        Nothing

    else
        Just key


fetchContent : Cmd Msg
fetchContent =
    Http.get { url = "/content", expect = Http.expectJson GotContent decoder }


decoder : D.Decoder Content
decoder =
    D.map3 Content
        (D.field "tabs" (D.list tabDecoder))
        (D.field "focus" (D.nullable D.string))
        (D.maybe (D.field "watching" (D.list D.string)) |> D.map (Maybe.withDefault []))


tabDecoder : D.Decoder Tab
tabDecoder =
    D.map3 Tab
        (D.field "name" D.string)
        (D.field "html" D.string)
        (D.field "mtime" D.int)



-- GROUPING


type alias Group =
    { key : String -- lowercased session — identity and active-matching
    , label : String -- display form ("repo@branch"), original case
    , tabs : List Tab -- newest-first
    }


{-| The session a tab belongs to. New-grammar names (`repo~branch~doc`) split on
the _last_ `~`. Names with no `~` fall back to the old rule — the segment before
the first `-` — so tabs written before the `~` grammar still group by project.
-}
sessionPart : String -> String
sessionPart name =
    if String.contains "~" name then
        case List.reverse (String.split "~" name) of
            _ :: session ->
                if List.isEmpty session then
                    name

                else
                    session |> List.reverse |> String.join "~"

            [] ->
                name

    else
        name |> String.split "-" |> List.head |> Maybe.withDefault name


{-| The grouping identity: the session part, lowercased so one project written in
different cases (`simnavlog` vs `SimNavLog`) folds into a single group.
-}
groupKey : String -> String
groupKey name =
    String.toLower (sessionPart name)


{-| The human label for a group: `repo@branch` for a `repo~branch` session, else
the session verbatim (a legacy name or a bare singleton like `plan`). `@` is
display-only — on disk the delimiter is `~`.
-}
groupLabel : String -> String
groupLabel name =
    if String.contains "~" name then
        case String.split "~" (sessionPart name) of
            repo :: branch ->
                if List.isEmpty branch then
                    repo

                else
                    repo ++ "@" ++ String.join "~" branch

            [] ->
                name

    else
        sessionPart name


{-| Fold the flat tab list into alphabetical groups (a `Dict` orders its keys),
each group's documents sorted newest-first so the head is the one to jump to. The
label is taken from the newest member, so a group reads in whatever case wrote
most recently.
-}
toGroups : List Tab -> List Group
toGroups tabs =
    tabs
        |> List.foldl
            (\t -> Dict.update (groupKey t.name) (\members -> Just (t :: Maybe.withDefault [] members)))
            Dict.empty
        |> Dict.toList
        |> List.map
            (\( key, members ) ->
                let
                    sorted =
                        List.sortBy (\t -> negate t.mtime) members

                    label =
                        sorted |> List.head |> Maybe.map (.name >> groupLabel) |> Maybe.withDefault key
                in
                { key = key, label = label, tabs = sorted }
            )


{-| The label for a dropdown entry: the document type after the session prefix
(`plan`, `summary`, `review`). New grammar takes the segment after the last `~`;
a legacy name takes the part after the first `-`; either falls back to the whole
name when there is no suffix.
-}
docLabel : String -> String
docLabel name =
    if String.contains "~" name then
        case List.reverse (String.split "~" name) of
            doc :: rest ->
                if List.isEmpty rest then
                    name

                else
                    doc

            [] ->
                name

    else
        case String.split "-" name of
            _ :: rest ->
                if List.isEmpty rest then
                    name

                else
                    String.join "-" rest

            [] ->
                name


relative : Int -> Int -> String
relative now mtime =
    let
        secs =
            max 0 (now - mtime)
    in
    if secs < 60 then
        "just now"

    else if secs < 3600 then
        String.fromInt (secs // 60) ++ "m ago"

    else if secs < 86400 then
        String.fromInt (secs // 3600) ++ "h ago"

    else
        String.fromInt (secs // 86400) ++ "d ago"



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "app" ]
        [ header model
        , backdrop model.openGroup
        , div [ class "tabs" ] (List.map (groupView model) (toGroups model.tabs))
        , contentPane model
        ]


header : Model -> Html Msg
header model =
    div [ class "header" ]
        [ span [ class "brand" ] [ text "ClaudeView" ]
        , span [ class "watching" ] [ text (watchingLabel model.watching) ]
        , span [ class "doc-title" ] [ text (Maybe.withDefault "" model.focus) ]
        , span
            [ classList [ ( "status", True ), ( "live", model.connected ) ] ]
            [ text
                (if model.connected then
                    "live"

                 else
                    "offline"
                )
            ]
        , button [ class "theme-toggle", onClick ToggleTheme ]
            [ text
                (if model.theme == "dark" then
                    "☀ light"

                 else
                    "☾ dark"
                )
            ]
        ]


watchingLabel : List String -> String
watchingLabel dirs =
    case dirs of
        [] ->
            "watching: (unknown)"

        _ ->
            "watching: " ++ String.join ", " dirs


{-| A group is a split-button: the label jumps to the newest document, the caret
opens a dropdown of the rest. The caret and menu appear only when there is more
than one document to choose between.
-}
groupView : Model -> Group -> Html Msg
groupView model g =
    let
        newest =
            List.head g.tabs

        isActive =
            Maybe.map groupKey model.focus == Just g.key

        multi =
            List.length g.tabs > 1

        live =
            g.key == "plan"

        label =
            if live then
                "plan (live)"

            else
                g.label
    in
    div [ class "tab-group" ]
        [ button
            [ classList [ ( "tab", True ), ( "active", isActive ), ( "live-plan", live ) ]
            , onClick (Focus (Maybe.withDefault g.key (Maybe.map .name newest)))
            ]
            [ text label ]
        , if multi then
            button [ class "tab-caret", onClick (ToggleGroup g.key) ] [ text "▾" ]

          else
            text ""
        , if multi && model.openGroup == Just g.key then
            div [ class "tab-menu" ] (List.map (menuItem model.now) g.tabs)

          else
            text ""
        ]


menuItem : Int -> Tab -> Html Msg
menuItem now t =
    button [ class "tab-menu-item", onClick (Focus t.name) ]
        [ span [ class "doc" ] [ text (docLabel t.name) ]
        , span [ class "ago" ] [ text (relative now t.mtime) ]
        ]


{-| An invisible full-window layer under any open menu: a click anywhere off the
menu lands here and closes it.
-}
backdrop : Maybe String -> Html Msg
backdrop open =
    case open of
        Just _ ->
            div [ class "menu-backdrop", onClick CloseMenu ] []

        Nothing ->
            text ""


contentPane : Model -> Html Msg
contentPane model =
    case List.filter (\t -> Just t.name == model.focus) model.tabs of
        t :: _ ->
            -- `<raw-html>` is a custom element (see index.html) that renders the
            -- server-produced HTML string, keeping this Elm code free of markdown.
            -- `docName` names the document so the element can remember its scroll.
            node "raw-html"
                [ class "content"
                , property "docName" (E.string t.name)
                , property "content" (E.string t.html)
                ]
                []

        [] ->
            div [ class "content empty" ]
                [ text (emptyMessage model.watching) ]


emptyMessage : List String -> String
emptyMessage dirs =
    case dirs of
        [] ->
            "Waiting for content…"

        _ ->
            "No tabs yet. Drop a .md file into " ++ String.join " or " dirs ++ ", or run a plan."



-- MAIN


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ sseMessage Ping
        , sseStatus Status
        , Time.every 60000 Tick
        ]


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
