module FxFlow
(
  -- * Fx
  flowForever,
  -- * Spawner
  Spawner,
  act,
  react,
  -- * Flow
  Flow,
  streamList,
)
where

import FxFlow.Prelude
import qualified Fx


-- * Producer
-------------------------

flowStreaming :: Spawner env err (Flow a) -> ListT (Fx env err) a
flowStreaming (Spawner rdr) = error "TODO"

flowForever :: Spawner env err (Flow ()) -> Fx env err Void
flowForever (Spawner spawn) = do

  errVar <- Fx.runSafeIO newEmptyTMVarIO

  let reportErr = atomically . void . tryPutTMVar errVar

  (Flow flow, (kill, block)) <-
    Fx.handleEnv $ \ env -> Fx.runSafeIO $
    runStateT (runReaderT spawn (env, reportErr)) (pure (), pure ())

  err <- Fx.runSafeIO $ atomically $ readTMVar errVar
  Fx.runSafeIO $ kill *> block
  throwErr err


-- * Spawner
-------------------------

newtype Spawner env err a = Spawner (ReaderT (env, err -> IO ()) (StateT (IO (), IO ()) IO) a)
  deriving (Functor, Applicative, Monad)

act :: ListT (Fx env err) out -> Spawner env err (Flow out)
act listT = fmap (\ flow -> flow ()) (react (const listT))

react :: (inp -> ListT (Fx env err) out) -> Spawner env err (inp -> Flow out)
react inpToListT = Spawner $ ReaderT $ \ (env, reportErr) -> StateT $ \ (kill, block) -> do

  regChan <- newTBQueueIO 100
  deathLockVar <- newEmptyMVar

  forkIO $ fix $ \ loop -> do
    msg <- atomically $ readTBQueue regChan
    case msg of
      Just (inp, emit) -> let
        eliminateListT (ListT accessor) = do
          result <- runExceptT $ runFx $ Fx.provideAndUse (pure env) accessor
          case result of
            Left err -> do
              reportErr err
              putMVar deathLockVar ()
            Right (Just (out, nextListT)) -> do
              emit out
              eliminateListT nextListT
            Right Nothing -> loop
        in eliminateListT (inpToListT inp)
      Nothing -> putMVar deathLockVar ()

  let
    flow inp = Flow (\ emit -> atomically (writeTBQueue regChan (Just (inp, emit))))
    newKill = kill *> atomically (writeTBQueue regChan Nothing)
    newBlock = block *> readMVar deathLockVar
    in return (flow, (newKill, newBlock))


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow a =
  {-|
  Action registering a callback.

  The idea is that the outer action is lightweight
  it deals with composition and message registration.
  The continuation action is lightweight aswell,
  it just gets executed on a different thread some time later on.
  -}
  Flow ((a -> IO ()) -> IO ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ emit -> emit a)
  (<*>) (Flow reg1) (Flow reg2) = Flow (\ emit -> reg1 (\ aToB -> reg2 (emit . aToB)))

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow $ \ emit -> reg1 $ k2 >>> \ (Flow reg2) -> reg2 emit

instance Alternative Flow where
  empty = Flow (\ emit -> return ())
  (<|>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> reg1 emit *> reg2 emit

instance MonadPlus Flow where
  mzero = empty
  mplus = (<|>)

instance Semigroup (Flow a) where
  (<>) = (<|>)

instance Monoid (Flow a) where
  mempty = empty
  mappend = (<>)

streamList :: [a] -> Flow a
streamList list = Flow $ \ emit -> forM_ list emit
