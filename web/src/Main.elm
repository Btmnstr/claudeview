port module Main exposing (main)

{-| The ClaudeView viewer.

It knows almost nothing: on every SSE ping it re-fetches `/content` (the list of
tabs, already rendered to HTML by the server, plus the directories being watched)
and shows the tab the server marks as focused — the most recently modified one.
Clicking a tab pins it until the next content change.

Tabs are named `<repo>~<branch>~<doc>`, so the viewer folds them into one
split-button per **repo**: the button jumps to that repo's newest document, and a
dropdown reaches the rest. The first `~`-segment is the group key, matched
case-insensitively; the branch moves into the dropdown labels (shown only when a
repo spans more than one). A name with no `~` falls back to the older rule (the
segment before the first `-`) so pre-`~` tabs still group.

A slim header shows what the server is watching, the document on screen, and
whether the live connection is up, so an empty screen still tells you where to look.

-}

import Browser
import Dict
import Html exposing (Html, button, div, node, span, text)
import Html.Attributes exposing (class, classList, property, title)
import Html.Events exposing (onClick)
import Http
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import Task
import Time



-- PORTS


port sseMessage : (String -> msg) -> Sub msg


port sseStatus : (Bool -> msg) -> Sub msg


port setTheme : String -> Cmd msg


{-| The `raw-html` element reports whether its scroll sits at the top, so the
model can auto-pin the moment you scroll away and unpin when you return.
-}
port scrollState : (Bool -> msg) -> Sub msg



-- MODEL


type alias Tab =
    { name : String, html : String, mtime : Int }


{-| How the reading pane decides to hold still on a content change. `FollowScroll`
is the default: unpinned at the top, auto-pinned once you scroll away. A click
takes manual control (`Pinned`/`Unpinned`) that sticks until you open another doc.
-}
type Pin
    = FollowScroll
    | Pinned
    | Unpinned


type alias Model =
    { tabs : List Tab
    , focus : Maybe String
    , watching : List String
    , connected : Bool
    , theme : String
    , openGroup : Maybe String -- the group whose dropdown is open, if any
    , now : Int -- POSIX seconds, so the dropdown can say "2h ago"
    , pin : Pin -- how the pane holds still: follow scroll, or a manual hold
    , atTop : Bool -- the reading pane is scrolled to the top
    , alerts : Set String -- group keys that gained new content while pinned
    }


{-| The flag is the theme JS resolved before first paint ("light" or "dark").
-}
init : String -> ( Model, Cmd Msg )
init theme =
    ( { tabs = [], focus = Nothing, watching = [], connected = False, theme = theme, openGroup = Nothing, now = 0, pin = FollowScroll, atTop = True, alerts = Set.empty }
    , Cmd.batch [ fetchContent, Task.perform Tick Time.now ]
    )


{-| Pinned means the view holds still on a content change. A manual hold wins
outright; otherwise we follow the scroll — pinned once you leave the top, so new
output never yanks away what you read.
-}
isPinned : Model -> Bool
isPinned model =
    case model.pin of
        Pinned ->
            True

        Unpinned ->
            False

        FollowScroll ->
            not model.atTop



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
    | TogglePin
    | Scrolled Bool


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Ping _ ->
            ( model, fetchContent )

        Status connected ->
            ( { model | connected = connected }, Cmd.none )

        GotContent (Ok content) ->
            ( if isPinned model then
                holdInPlace model content

              else
                adoptFocus model content
            , Cmd.none
            )

        GotContent (Err _) ->
            ( model, Cmd.none )

        Focus name ->
            -- Selecting a document starts unpinned-at-top, closes the menu, and
            -- clears this group's dot (the newest doc is the one it flagged).
            ( { model | focus = Just name, openGroup = Nothing, pin = FollowScroll, atTop = True, alerts = clearAlert (Just name) model.alerts }, Cmd.none )

        ToggleGroup key ->
            ( { model | openGroup = toggleOpen key model.openGroup }, Cmd.none )

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

        TogglePin ->
            -- Take manual control of the *effective* state, so a click while
            -- scrolled can force unpinned — not just add a pin on top of the
            -- scroll. The choice sticks until another document is opened.
            ( { model
                | pin =
                    if isPinned model then
                        Unpinned

                    else
                        Pinned
              }
            , Cmd.none
            )

        Scrolled top ->
            ( { model | atTop = top }, Cmd.none )


{-| A content refresh while pinned: hold our focus and scroll, but take the new
tab list and dot any group that gained content behind the pin.
-}
holdInPlace : Model -> Content -> Model
holdInPlace model content =
    { model | tabs = content.tabs, watching = content.watching, alerts = markAlerts model content }


{-| A content refresh while unpinned: adopt the server's focus (newest-modified)
and clear that group's dot.
-}
adoptFocus : Model -> Content -> Model
adoptFocus model content =
    { model
        | tabs = content.tabs
        , focus = content.focus
        , watching = content.watching
        , alerts = clearAlert content.focus model.alerts
    }


{-| Fold the groups that gained content since our last snapshot into the alert
set: a tab is fresh when it is new or its mtime bumped, and it is not the doc on
screen. Only ever called while pinned, so the first load never raises a dot.
-}
markAlerts : Model -> Content -> Set String
markAlerts model content =
    let
        prev =
            Dict.fromList (List.map (\t -> ( t.name, t.mtime )) model.tabs)

        isFresh t =
            Dict.get t.name prev /= Just t.mtime
    in
    content.tabs
        |> List.filter isFresh
        |> List.filter (\t -> Just t.name /= model.focus)
        |> List.map (.name >> groupKey)
        |> List.foldl Set.insert model.alerts


{-| Drop the dot for the group a focused document belongs to — it has been seen.
-}
clearAlert : Maybe String -> Set String -> Set String
clearAlert focus alerts =
    case focus of
        Just name ->
            Set.remove (groupKey name) alerts

        Nothing ->
            alerts


toggleOpen : String -> Maybe String -> Maybe String
toggleOpen key open =
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
    { key : String -- lowercased repo — identity and active-matching
    , label : String -- display form (the repo), original case
    , tabs : List Tab -- newest-first
    }


{-| Split a tab name into its segments on the grammar's delimiter: `~` for current
names (`repo~branch~doc`), the legacy `-` for names written before it. Every
name-part function shares this, so the two grammars stay in lockstep.
-}
splitName : String -> List String
splitName name =
    String.split
        (if String.contains "~" name then
            "~"

         else
            "-"
        )
        name


last : List a -> Maybe a
last =
    List.reverse >> List.head


{-| The group a tab belongs to: the first segment — the repo. Every branch of a
repo folds into one group; the branch moves into the document label instead.
-}
sessionPart : String -> String
sessionPart name =
    splitName name |> List.head |> Maybe.withDefault name


{-| The document type: the last segment (`plan`, `summary`, `nuc-setup`). A legacy
multi-hyphen name keeps only its final word — those are retired by the `~` grammar.
-}
docPart : String -> String
docPart name =
    splitName name |> last |> Maybe.withDefault name


{-| The branch a tab belongs to, or `""` when there is none to show. A branch
exists only in the current grammar — exactly three `~`-segments, `repo~branch~doc` —
so this splits on `~` directly rather than pretend a legacy hyphen-name has one.
-}
branchPart : String -> String
branchPart name =
    case String.split "~" name of
        [ _, branch, _ ] ->
            branch

        _ ->
            ""


{-| The grouping identity: the session part, lowercased so one project written in
different cases (`simnavlog` vs `SimNavLog`) folds into a single group.
-}
groupKey : String -> String
groupKey name =
    String.toLower (sessionPart name)


{-| The human label for a group: just the repo. Branches live in the document
labels now, so a group reads as the bare project name.
-}
groupLabel : String -> String
groupLabel name =
    sessionPart name


{-| The reserved group key whose tab shows the live plan-mode document.
-}
livePlanKey : String
livePlanKey =
    "plan"


{-| Whether a group holds documents from more than one branch — the cue to prefix
each dropdown entry with its branch.
-}
groupSpansMultipleBranches : Group -> Bool
groupSpansMultipleBranches group =
    let
        branches =
            group.tabs
                |> List.map (.name >> branchPart)
                |> List.filter (\b -> b /= "")
                |> unique
    in
    List.length branches > 1


{-| The name of a group's newest document — where its primary button jumps to.
-}
newestDocName : Group -> String
newestDocName group =
    group.tabs |> List.head |> Maybe.map .name |> Maybe.withDefault group.key


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
            [ text (statusLabel model.connected) ]
        , button [ class "theme-toggle", onClick ToggleTheme ]
            [ text (themeToggleLabel model.theme) ]
        ]


watchingLabel : List String -> String
watchingLabel dirs =
    case dirs of
        [] ->
            "watching: (unknown)"

        _ ->
            "watching: " ++ String.join ", " dirs


statusLabel : Bool -> String
statusLabel connected =
    if connected then
        "live"

    else
        "offline"


themeToggleLabel : String -> String
themeToggleLabel theme =
    if theme == "dark" then
        "☀ light"

    else
        "☾ dark"


{-| A group is a split-button: the label jumps to the newest document, the caret
opens a dropdown of the rest. The caret and menu appear only when there is more
than one document to choose between.
-}
groupView : Model -> Group -> Html Msg
groupView model group =
    let
        isActive =
            Maybe.map groupKey model.focus == Just group.key

        multi =
            List.length group.tabs > 1

        live =
            group.key == livePlanKey

        label =
            if live then
                "plan (live)"

            else
                group.label
    in
    div [ class "tab-group" ]
        [ button
            [ classList [ ( "tab", True ), ( "active", isActive ), ( "live-plan", live ) ]
            , onClick (Focus (newestDocName group))
            ]
            [ text label
            , viewIf (Set.member group.key model.alerts) (span [ class "dot" ] [])
            ]
        , viewIf multi (caretButton group.key)
        , viewIf (multi && model.openGroup == Just group.key)
            (groupMenu model.now (groupSpansMultipleBranches group) group.tabs)
        ]


{-| The caret that opens a group's dropdown of documents.
-}
caretButton : String -> Html Msg
caretButton key =
    button [ class "tab-caret", onClick (ToggleGroup key) ] [ text "▾" ]


{-| The dropdown listing a group's documents newest-first.
-}
groupMenu : Int -> Bool -> List Tab -> Html Msg
groupMenu now showBranch tabs =
    div [ class "tab-menu" ] (List.map (menuItem now showBranch) tabs)


{-| A dropdown entry: the document type, prefixed with its branch only when the
group actually spans more than one branch (so single-branch repos stay uncluttered).
-}
menuItem : Int -> Bool -> Tab -> Html Msg
menuItem now showBranch tab =
    let
        entry =
            if showBranch && branchPart tab.name /= "" then
                branchPart tab.name ++ " / " ++ docPart tab.name

            else
                docPart tab.name
    in
    button [ class "tab-menu-item", onClick (Focus tab.name) ]
        [ span [ class "doc" ] [ text entry ]
        , span [ class "ago" ] [ text (relative now tab.mtime) ]
        ]


{-| The distinct elements of a list, order preserved.
-}
unique : List a -> List a
unique =
    List.foldr
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


{-| Render `el` only when `cond` holds, otherwise nothing — the declarative form
of the repeated `if cond then el else text ""`.
-}
viewIf : Bool -> Html msg -> Html msg
viewIf cond el =
    if cond then
        el

    else
        text ""


{-| An invisible full-window layer under any open menu: a click anywhere off the
menu lands here and closes it.
-}
backdrop : Maybe String -> Html Msg
backdrop open =
    viewIf (open /= Nothing) (div [ class "menu-backdrop", onClick CloseMenu ] [])


contentPane : Model -> Html Msg
contentPane model =
    case List.filter (\tab -> Just tab.name == model.focus) model.tabs of
        tab :: _ ->
            -- The pin sits fixed over the top-left of the scrolling body, so it
            -- rides in a positioned wrapper rather than inside `raw-html` itself.
            -- `<raw-html>` is a custom element (see index.html) that renders the
            -- server-produced HTML string, keeping this Elm code free of markdown.
            -- `docName` names the document so the element can remember its scroll.
            div [ class "content-pane" ]
                [ pinButton model
                , node "raw-html"
                    [ class "content"
                    , property "docName" (E.string tab.name)
                    , property "content" (E.string tab.html)
                    ]
                    []
                ]

        [] ->
            div [ class "content empty" ]
                [ text (emptyMessage model.watching) ]


{-| The pin toggle, fixed to the body's top-left. Bright when the view is held,
faint otherwise; the tooltip explains both how it got there and how to change it.
-}
pinButton : Model -> Html Msg
pinButton model =
    button
        [ classList [ ( "pin", True ), ( "pinned", isPinned model ) ]
        , onClick TogglePin
        , title
            (if isPinned model then
                "Pinned — new documents won't steal the view. Click to unpin."

             else
                "Unpinned. Click to pin, or scroll down to pin automatically."
            )
        ]
        [ text "📌" ]


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
        , scrollState Scrolled
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
