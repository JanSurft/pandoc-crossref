module References.Blocks (replaceBlocks) where

import Text.Pandoc.Definition
import Text.Pandoc.Builder (text, toList)
import Text.Pandoc.Shared (stringify, normalizeSpaces)
import Control.Monad.State
import Data.List
import qualified Data.Map as M

import Util.Accessor
import References.Types
import References.Accessors
import Util.Util
import Util.Options
import Util.Template

replaceBlocks :: Options -> Block -> WS Block
replaceBlocks _opts x@(Header n (label, cls, _) text')
  = do
    unless ("unnumbered" `elem` cls) $ do
      modify $ \r@References{curChap=cc} ->
        let ln = length cc
            inc l = init l ++ [last l + 1]
            cc' | ln > n = inc $ take n cc
                | ln == n = inc cc
                | otherwise = cc ++ take (n-ln) [1,1..]
        in r{curChap=cc'}
      when ("sec:" `isPrefixOf` label) $ do
        replaceAttrSec label text' secRefs'
        return ()
    return x
replaceBlocks opts (Para (Image alt img:c))
  | Just label <- getRefLabel "fig" c
  = do
    idxStr <- replaceAttr opts label alt imgRefs'
    let alt' = case outFormat opts of
          f | isFormat "latex" f ->
            RawInline (Format "tex") ("\\label{"++label++"}") : alt
          _  -> applyTemplate idxStr alt $ figureTemplate opts
    return $ Para [Image alt' (fst img,"fig:")]
replaceBlocks opts (Para (Math DisplayMath eq:c))
  | Just label <- getRefLabel "eq" c
  = case outFormat opts of
      f | isFormat "latex" f ->
        let eqn = "\\begin{equation}"++eq++"\\label{"++label++"}\\end{equation}"
        in return $ Para [RawInline (Format "tex") eqn]
      _ -> do
        idxStr <- replaceAttr opts label [] eqnRefs'
        let eq' = eq++"\\qquad("++stringify idxStr++")"
        return $ Para [Math DisplayMath eq']
replaceBlocks opts (Table title align widths header cells)
  | not $ null title
  , Just label <- getRefLabel "tbl" [last title]
  = do
    idxStr <- replaceAttr opts label (init title) tblRefs'
    let title' =
          case outFormat opts of
              f | isFormat "latex" f ->
                RawInline (Format "tex") ("\\label{"++label++"}") : init title
              _  -> applyTemplate idxStr (init title) $ tableTemplate opts
    return $ Table title' align widths header cells
replaceBlocks opts cb@(CodeBlock (label, classes, attrs) code)
  | not $ null label
  , "lst:" `isPrefixOf` label
  , Just caption <- lookup "caption" attrs
  = case outFormat opts of
      f
        --if used with listings package,nothing shoud be done
        | isFormat "latex" f, useListings opts -> return cb
        --if not using listings, however, wrap it in a codelisting environment
        | isFormat "latex" f ->
          return $ Div nullAttr [
              RawBlock (Format "tex")
                $ "\\begin{codelisting}\n\\caption{"++caption++"}"
            , cb
            , RawBlock (Format "tex") "\\end{codelisting}"
            ]
      _ -> do
        let cap = toList $ text caption
        idxStr <- replaceAttr opts label cap lstRefs'
        let caption' = applyTemplate idxStr cap $ listingTemplate opts
        return $ Div (label, "listing":classes, []) [
            Para caption'
          , CodeBlock ([], classes, attrs \\ [("caption", caption)]) code
          ]
replaceBlocks opts
  (Div (label,"listing":_, [])
    [Para caption, CodeBlock ([],classes,attrs) code])
  | not $ null label
  , "lst:" `isPrefixOf` label
  = case outFormat opts of
      f
        --if used with listings package, return code block with caption
        | isFormat "latex" f, useListings opts ->
          return $ CodeBlock (label,classes,("caption",stringify caption):attrs) code
        --if not using listings, however, wrap it in a codelisting environment
        | isFormat "latex" f ->
          return $ Div nullAttr [
              RawBlock (Format "tex") "\\begin{codelisting}"
            , Para [RawInline (Format "tex") "\\caption",Span nullAttr caption]
            , CodeBlock (label,classes,attrs) code
            , RawBlock (Format "tex") "\\end{codelisting}"
            ]
      _ -> do
        idxStr <- replaceAttr opts label caption lstRefs'
        let caption' = applyTemplate idxStr caption $ listingTemplate opts
        return $ Div (label, "listing":classes, []) [
            Para caption'
          , CodeBlock ([], classes, attrs) code
          ]
replaceBlocks _ x = return x

getRefLabel :: String -> [Inline] -> Maybe String
getRefLabel _ [] = Nothing
getRefLabel tag ils
  | Str attr <- last ils
  , all (==Space) (init ils)
  , "}" `isSuffixOf` attr
  , ("{#"++tag++":") `isPrefixOf` attr
  = init `fmap` stripPrefix "{#" attr
getRefLabel _ _ = Nothing

replaceAttr :: Options -> String -> [Inline] -> Accessor References RefMap -> WS [Inline]
replaceAttr o label title prop
  = do
    chap  <- take (chapDepth o) `fmap` gets curChap
    index <- (1+) `fmap` gets (M.size . M.filter ((==chap) . fst . refIndex) . getProp prop)
    modify $ modifyProp prop $ M.insert label RefRec {
      refIndex=(chap,index)
    , refTitle=normalizeSpaces title
    }
    return $ chapPrefix (chapDelim o) chap index

replaceAttrSec :: String -> [Inline] -> Accessor References RefMap -> WS ()
replaceAttrSec label title prop
  = do
    chap  <- gets curChap
    modify $ modifyProp prop $ M.insert label RefRec {
      refIndex=(init chap,last chap)
    , refTitle=normalizeSpaces title
    }
    return ()