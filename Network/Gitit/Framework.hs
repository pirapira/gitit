{-# LANGUAGE ScopedTypeVariables #-}
{-
Copyright (C) 2009 John MacFarlane <jgm@berkeley.edu>
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- General framework for defining wiki actions. 
-}

module Network.Gitit.Framework ( getLoggedInUser
                               , sessionTime
                               , unlessNoEdit
                               , unlessNoDelete
                               , getPath
                               , getPage
                               , getReferer
                               , getWikiBase
                               , uriPath
                               , isPage
                               , isPageFile
                               , isDiscussPage
                               , isDiscussPageFile
                               , isSourceCode
                               , isPreview
                               , urlForPage
                               , pathForPage
                               , getMimeTypeForExtension
                               , ifLoggedIn
                               , validate
                               , guardCommand
                               , guardPath
                               , guardIndex
                               , withInput
                               , filestoreFromConfig
                               )
where
import Network.Gitit.Server
import Network.Gitit.State
import Network.Gitit.Types
import Data.FileStore
import Data.Char (toLower, isAscii, isDigit, isLetter)
import Control.Monad (mzero, liftM, MonadPlus)
import qualified Data.Map as M
import Data.ByteString.UTF8 (toString)
import Data.ByteString.Lazy.UTF8 (fromString)
import Data.Maybe (fromJust)
import Data.List (intercalate, isSuffixOf, (\\))
import System.FilePath ((<.>), takeExtension, dropExtension)
import Text.Highlighting.Kate
import Text.ParserCombinators.Parsec
import Network.URL (decString, encString)
import Happstack.Crypto.Base64 (decode)

getLoggedInUser :: GititServerPart (Maybe User)
getLoggedInUser = withData $ \(sk :: Maybe SessionKey) -> do
  cfg <- getConfig
  case authenticationMethod cfg of
       HTTPAuth -> do
         req <- askRq
         case (getHeader "authorization" req) of
              Just authHeader -> case parse pAuthorizationHeader "" (toString authHeader) of
                                 Left _  -> return Nothing
                                 Right u -> return $ Just $
                                              User{ uUsername = u,
                                                    uPassword = undefined,
                                                    uEmail    = "" }
              Nothing         -> return Nothing
       FormAuth -> do
         mbSd <- maybe (return Nothing) getSession sk
         case mbSd of
              Nothing    -> return Nothing
              Just sd    -> getUser $! sessionUser sd
       CustomAuth customGetLoggedInUser -> customGetLoggedInUser

pAuthorizationHeader :: GenParser Char st String
pAuthorizationHeader = try pBasicHeader <|> pDigestHeader

pDigestHeader :: GenParser Char st String
pDigestHeader = do
  string "Digest username=\""
  result' <- many (noneOf "\"")
  char '"'
  return result'

pBasicHeader :: GenParser Char st String
pBasicHeader = do
  string "Basic "
  result' <- many (noneOf " \t\n")
  return $ takeWhile (/=':') $ decode result'

sessionTime :: Int
sessionTime = 60 * 60     -- session will expire 1 hour after page request

unlessNoEdit :: Handler
             -> Handler
             -> Handler
unlessNoEdit responder fallback = withData $ \(params :: Params) -> do
  cfg <- getConfig
  page <- getPage
  if page `elem` noEdit cfg
     then withInput "messages" ("Page is locked." : pMessages params) fallback
     else responder

unlessNoDelete :: Handler
               -> Handler
               -> Handler
unlessNoDelete responder fallback = withData $ \(params :: Params) -> do
  cfg <- getConfig
  page <- getPage
  if page `elem` noDelete cfg
     then withInput "messages" ("Page cannot be deleted." : pMessages params) fallback
     else responder

getPath :: ServerMonad m => m String
getPath = liftM (fromJust . decString True . intercalate "/" . rqPaths) askRq

getPage :: GititServerPart String
getPage = do
  conf <- getConfig
  path' <- getPath
  if null path'
     then return (frontPage conf)
     else return path'

getReferer :: ServerMonad m => m String
getReferer = do
  req <- askRq
  base' <- getWikiBase
  return $ case getHeader "referer" req of
                 Just r  -> case toString r of
                                 ""  -> base'
                                 s   -> s
                 Nothing -> base'

-- | Returns the base URL of the wiki in the happstack server.
-- So, if the wiki handlers are behind a dir "foo", getWikiBase will
-- return '/foo/'.  getWikiBase doesn't know anything about HTTP
-- proxies, so if you use proxies to map a gitit wiki to /foo/,
-- you'll still need to follow the instructions in README.
getWikiBase :: ServerMonad m => m String
getWikiBase = do
  path' <- getPath
  uri <- liftM (fromJust . decString True . rqUri) askRq
  if null path' -- we're at / or something like /_index
     then return $ takePrefix uri 
     else do
       let path'' = if last uri == '/' then path' ++ "/" else path'
       if path'' `isSuffixOf` uri
          then let pref = take (length uri - length path'') uri
               in  return $ if not (null pref) && last pref == '/'
                               then init pref
                               else pref
          else error $ "Could not getWikiBase: (path, uri) = " ++ show (path'',uri)

takePrefix :: String -> String
takePrefix "" = ""
takePrefix "/" = ""
takePrefix ('/':'_':_) = ""
takePrefix (x:xs) = x : takePrefix xs

-- | Returns path portion of URI, without initial /.
-- Consecutive spaces are collapsed.  We don't want to distinguish 'Hi There' and 'Hi  There'.
uriPath :: String -> String
uriPath = unwords . words . drop 1 . takeWhile (/='?')

isPage :: String -> Bool
isPage _ = True

isPageFile :: FilePath -> Bool
isPageFile f = takeExtension f == ".page"

isDiscussPage :: String -> Bool
isDiscussPage s = isPage s && ":discuss" `isSuffixOf` s

isDiscussPageFile :: FilePath -> Bool
isDiscussPageFile f = isPageFile f && ":discuss" `isSuffixOf` (dropExtension f)

isSourceCode :: String -> Bool
isSourceCode path' =
  let ext   = map toLower $ takeExtension path'
      langs = languagesByExtension ext \\ ["Postscript"]
  in  not . null $ langs

isPreview :: String -> Bool
isPreview x = "/___preview" `isSuffixOf` x
-- We choose something that is unlikely to occur naturally as a suffix.
-- Why suffix and not prefix?  Because the link is added by a script,
-- and mod_proxy_html doesn't rewrite links in scripts.  So this is
-- to make it possible to use gitit with an alternative docroot.

urlForPage :: String -> String -> String
urlForPage base' page = base' ++ "/" ++
  encString True (\c -> isAscii c && (isLetter c || isDigit c || c `elem` "/:")) page
-- / and : are left unescaped so that browsers recognize relative URLs and talk pages correctly

pathForPage :: String -> FilePath
pathForPage page = page <.> "page"

getMimeTypeForExtension :: String -> GititServerPart String
getMimeTypeForExtension ext = do
  mimes <- liftM mimeMap getConfig
  return $ case M.lookup (dropWhile (=='.') $ map toLower ext) mimes of
                Nothing -> "application/octet-stream"
                Just t  -> t

ifLoggedIn :: Handler
           -> Handler
           -> Handler
ifLoggedIn responder fallback = withData $ \(sk :: Maybe SessionKey) -> do
  user <- getLoggedInUser
  case user of
       Nothing  -> do
          localRq (\rq -> setHeader "referer" (rqUri rq ++ rqQuery rq) rq) fallback
       Just _   -> do
          -- give the user more time...
          case sk of
               Just key  -> addCookie sessionTime (mkCookie "sid" (show key))
               Nothing   -> return ()
          responder

validate :: [(Bool, String)]   -- ^ list of conditions and error messages
         -> [String]           -- ^ list of error messages
validate = foldl go []
   where go errs (condition, msg) = if condition then msg:errs else errs

guardCommand :: String -> GititServerPart ()
guardCommand command = withData $ \(com :: Command) ->
  case com of
       Command (Just c) | c == command -> return ()
       _                               -> mzero

guardPath :: (String -> Bool) -> GititServerPart ()
guardPath pred' = guardRq (pred' . rqUri)

guardIndex :: GititServerPart ()
guardIndex = do
  base <- getWikiBase
  uri' <- liftM rqUri askRq
  if uri' /= base && last uri' == '/'
     then return ()
     else mzero

withInput :: Show a => String -> a -> Handler -> Handler
withInput name val handler = do
  req <- askRq
  let inps = filter (\(n,_) -> n /= name) $ rqInputs req
  let newInp = (name, Input { inputValue = fromString $ show val
                            , inputFilename = Nothing
                            , inputContentType = ContentType {
                                    ctType = "text"
                                  , ctSubtype = "plain"
                                  , ctParameters = [] }
                            })
  localRq (\rq -> rq{ rqInputs = newInp : inps }) handler

filestoreFromConfig :: Config -> FileStore
filestoreFromConfig conf =
  case repositoryType conf of
         Git   -> gitFileStore $ repositoryPath conf
         Darcs -> darcsFileStore $ repositoryPath conf