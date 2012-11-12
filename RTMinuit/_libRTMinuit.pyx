from libcpp.vector cimport vector
from libcpp.string cimport string
from cpython cimport exc
#from libcpp import bool
from util import *
from warnings import warn
from cython.operator cimport dereference as deref
from libc.math cimport sqrt
from pprint import pprint
include "Lcg_Minuit.pxi"

#our wrapper
cdef extern from "PythonFCN.h":
    #int raise_py_err()#this is very important we need custom error handler
    FunctionMinimum* call_mnapplication_wrapper(MnApplication app,unsigned int i, double tol) except +
    cdef cppclass PythonFCN(FCNBase):
        PythonFCN(object fcn, double up_parm, vector[string] pname,bint thrownan)
        double call "operator()" (vector[double] x) except +#raise_py_err
        double up()
        int getNumCall()
        void resetNumCall()


class bcolors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'


#look up map with default
cdef maplookup(m,k,d):
    return m[k] if k in m else d


cdef cfmin2struct(FunctionMinimum* cfmin):
    cfmin_struct = Struct(
            fval = cfmin.fval(),
            edm = cfmin.edm(),
            nfcn = cfmin.nfcn(),
            up = cfmin.up(),
            is_valid = cfmin.isValid(),
            has_valid_parameters = cfmin.hasValidParameters(),
            has_accurate_covar = cfmin.hasAccurateCovar(),
            has_posdef_covar = cfmin.hasPosDefCovar(),
            has_made_posdef_covar = cfmin.hasMadePosDefCovar(),#forced to be posdef
            hesse_failed = cfmin.hesseFailed(),
            has_covariance = cfmin.hasCovariance(),
            is_above_max_edm = cfmin.isAboveMaxEdm(),
            has_reached_call_limit = cfmin.hasReachedCallLimit()
        )
    return cfmin_struct

cdef minuitparam2struct(MinuitParameter* mp):
    ret = Struct(
            number = mp.number(),
            naem = mp.name(),
            value = mp.value(),
            error = mp.error(),
            is_const = mp.isConst(),
            is_fixed = mp.isFixed(),
            has_limits = mp.hasLimits(),
            has_lower_limit = mp.hasLowerLimit(),
            has_upper_limit = mp.hasUpperLimit(),
            lower_limit = mp.lowerLimit(),
            upper_limit = mp.upperLimit(),
        )
    return ret

cdef cfmin2covariance(FunctionMinimum cfmin, int n):
    #not depending on numpy on purpose
    #cdef int n = cfmin.userState().params.size()
    return [[cfmin.userCovariance().get(i,j) for i in range(n)] for j in range(n)]


cdef cfmin2correlation(FunctionMinimum cfmin, int n):
    #cdef int n = cfmin.userState().params.size()
    #not depending on numpy on purpose
    return [[cfmin.userCovariance().get(i,j)/sqrt(cfmin.userCovariance().get(i,i))/sqrt(cfmin.userCovariance().get(j,j)) \
        for i in range(n)] for j in range(n)]

cdef minoserror2struct(MinosError m):
        ret = Struct(
            lower = m.lower(),
            upper = m.upper(),
            is_valid = m.isValid(),
            lower_valid = m.lowerValid(),
            upper_valid = m.upperValid(),
            at_lower_limit = m.atLowerLimit(),
            at_upper_limit = m.atUpperLimit(),
            at_lower_max_fcn = m.atLowerMaxFcn(),
            at_upper_max_fcn = m.atUpperMaxFcn(),
            lower_new_min = m.lowerNewMin(),
            upper_new_min = m.upperNewMin(),
            nfcn = m.nfcn(),
            min = m.min()
            )
        return ret


cdef class Minuit:
    #standard stuff
    cdef readonly object fcn #:fcn
    cdef readonly object varname #:variable names
    cdef readonly object pos2var
    cdef readonly object var2pos

    #Initial settings
    cdef object initialvalue #:hold initial values
    cdef object initialerror #:hold initial errors
    cdef object initiallimit #:hold initial limits
    cdef object initialfix #:hold initial fix state

    #C++ object state
    cdef PythonFCN* pyfcn #:FCN
    cdef MnApplication* minimizer #:migrad
    cdef FunctionMinimum* cfmin #:last migrad result
    cdef MnUserParameterState* last_upst #:last parameter state(from hesse/migrad)

    #PyMinuit compatible field
    cdef public double up #:UP parameter
    cdef public double tol #:tolerance migrad stops when edm>0.0001*tol*UP
    cdef public unsigned int strategy #:
    cdef public print_mode
    cdef readonly bint throw_nan

    #PyMinuit Compatible interface
    cdef readonly object parameters
    cdef readonly object args
    cdef readonly object values
    cdef readonly object errors
    cdef readonly object covariance
    cdef readonly double fval
    cdef readonly double ncalls
    cdef readonly double edm
    cdef readonly object merrors

    #and some extra
    cdef public object fitarg
    cdef readonly object narg
    cdef public object merrors_struct


    def __init__(self, fcn, throw_nan=False, print_mode=0, pedantic=True, **kwds):
        """
        construct minuit object
        arguments of f are pased automatically by the following order
        1) using f.func_code.co_varnames,f.func_code.co_argcount (all python function has this)
        2) using f.__call__.func_code.co_varnames, f.__call__.co_argcount (with self docked off)
        3) using inspect.getargspec(for some rare builtin function)

        user can set limit on paramater by passing limit_<varname>=(min,max) keyword argument
        user can set initial value onparameter by passing <varname>=value keyword argument
        user can fix parameter by doing fix_<varname>=True
        user can set initial step by passing error_<varname>=initialstep keyword argument

        if f_verbose is set to True FCN will be built for verbosity printing value and argument for every function call
        """

        args = better_arg_spec(fcn)
        narg = len(args)
        self.fcn = fcn

        #maintain 2 dictionary 1 is position to varname
        #and varname to position
        self.varname = args
        self.pos2var = {i: k for i, k in enumerate(args)}
        self.var2pos = {k: i for i, k in enumerate(args)}

        #self.set_printlevel(printlevel)
        #self.prepare(**kwds)

        self.last_migrad_result = 0
        self.args, self.values, self.errors = None, None, None

        if pedantic: self.pedantic(kwds)

        self.initialvalue = {x:maplookup(kwds,x,0.) for x in self.varname}
        self.initialerror = {x:maplookup(kwds,'error_'+x,1.) for x in self.varname}
        self.initiallimit = {x:maplookup(kwds,'limit_'+x,None) for x in self.varname}
        self.initialfix = {x:maplookup(kwds,'fix_'+x,False) for x in self.varname}

        self.pyfcn = NULL
        self.minimizer = NULL
        self.cfmin = NULL
        self.last_upst = NULL

        self.up = 1.0
        self.tol = 0.1
        self.strategy = 1
        self.print_mode = print_mode
        self.throw_nan = throw_nan

        self.parameters = args
        self.args = None
        self.values = None
        self.errors = None
        self.covariance = None
        self.fval = None
        self.ncalls = 0
        self.edm = 0
        self.merrors = {}
        self.fitarg = {}
        fitarg.update(self.initialvalue)
        fitarg.update({'error_'+k:v for k,v in self.initialerror.items()})
        fitarg.update({'limit_'+k:v for k,v in self.initiallimit.items()})
        fitarg.update({'fix_'+k:v for k,v in self.initialfix.items()})
        self.narg = len(varname)

        self.merrors_struct = {}


    cdef construct_FCN(self):
        del self.pyfcn
        self.pyfcn = new PythonFCN(self.fcn,self.errordef,self.varname,False)


    def is_clean_state(self):
        return self.pyfcn is NULL and self.minimizer is NULL and self.cfmin is NULL


    cdef void clear_cobj(self):

        del self.pyfcn
        del self.minimizer
        del self.cfmin
        del self.last_upst
        self.pyfcn = NULL
        self.minimizer = NULL
        self.cfmin = NULL
        self.last_upst = NULL

    def __dealloc__(self):
        self.clear_cobj()

    def pedantic(self, kwds):
        for vn in self.varname:
            if vn not in kwds:
                warn('Parameter %s does not have initial value. Assume 0.' % (vn))
            if 'error_'+vn not in kwds and 'fix_'+param_name(vn) not in kwds:
                warn('Parameter %s is floating but does not have initial step size. Assume 1.' % (vn))
        for vlim in extract_limit(kwds):
            if param_name(vlim) not in self.varname:
                warn('%s is given. But there is no parameter %s.Ignore.' % (vlim, param_name(vlim)))
        for vfix in extract_fix(kwds):
            if param_name(vfix) not in self.varname:
                warn('%s is given. But there is no parameter %s.Ignore.' % (vfix, param_name(vfix)))
        for verr in extract_error(kwds):
            if param_name(verr) not in self.varname :
                warn('%s float. But there is no parameter %s.Ignore.' % (verr, param_name(verr)))
        
    def refreshInternalState(self):
        #this is only to keep backward compatible with PyMinuit
        #it should be in a function instead of a state for lazy-callable
        cdef vector[MinuitParameter] mpv

        if self.last_upst is not NULL:
            mpv = self.last_upst.minuitParameters()
            self.values = {}
            self.errors = {}
            self.args = []
            for i in range(mpv.size()):
                self.args = mpv[i].value()
                self.values[mpv[i].name()] = mpv[i].value()
                self.errors[mpv[i].name()] = mpv[i].value()
            self.args = tuple(self.args)
            self.fitarg.update(self.values)
            self.covariance =\
                {(varname[i],varname[j]):self.last_upst.covariance().get(i,j)\
                    for i in range(self.narg) for j in range(self.narg)}
            self.fval = self.last_upst.fval()
            self.ncalls = self.last_upst.nfcn()
            self.edm = self.last_upst.edm()
            self.gcc = {v:self.last_upst.globalCC().globalCC()[i] for i,v in enumerate(varname)}
        self.merrors = {(k,1.0):v.upper for k,v in self.merrors_struct}
        self.merrors.update({(k,-1.0):v.lower for k,v in self.merrors_struct})
        pass

    cdef MnUserParameterState* initialParameterState(self):
        cdef MnUserParameterState* ret = new MnUserParameterState()
        cdef double lb
        cdef double ub
        for v in self.varname:
            ret.add(v,self.initialvalue[v],self.initialerror[v])
        for v in self.varname:
            if self.initiallimit[v] is not None:
                lb,ub = self.initiallimit[v]
                ret.setLimits(v,lb,ub)
        for v in self.varname:
            if self.initialfix[v]:
                ret.fix(v)
        return ret

    def migrad(self,int ncall=1000,resume=True,double tolerance=0.1, print_interval=100, print_at_the_end=True):
        """
            run migrad
            user can check if the return status is not 0
        """
        #construct new fcn and migrad if
        #it's a clean state or resume=False
        cdef MnUserParameterState* ups = NULL
        cdef MnStrategy* strat = NULL
        self.print_banner('MIGRAD')
        if not resume or self.is_clean_state():
            self.construct_FCN()
            if self.minimizer is not NULL: del self.minimizer
            ups = self.initialParameterState()
            strat = new MnStrategy(self.strategy)
            self.minimizer = new MnMigrad(deref(self.pyfcn),deref(ups),deref(strat))
            del ups; ups=NULL
            del strat; strat=NULL

        del self.cfmin #remove the old one
        #this returns a real object need to copy
        self.cfmin = call_mnapplication_wrapper(deref(self.minimizer),ncall,tolerance)
        del self.last_upst
        self.last_upst = new MnUserParameterState(self.cfmin.userState())
        self.refreshInternalState()
        if print_at_the_end: self.print_cfmin(tolerance)


    def hesse(self,unsigned int strategy=1):

        cdef MnHesse* hesse = NULL
        cdef MnUserParameterState upst
        self.print_banner('HESSE')
        #if self.cfmin is NULL:
            #raise RuntimeError('Run migrad first')
        hesse = new MnHesse(strategy)
        upst = hesse.call(deref(self.pyfcn),self.cfmin.userState())

        del self.last_upst
        self.last_upst = new MnUserParameterState(upst)
        self.refreshInternalState()
        del hesse


    def minos(self, var = None, sigma = 1, unsigned int strategy=1, unsigned int maxcall=1000):
        cdef unsigned int index = 0
        cdef MnMinos* minos = NULL
        cdef MinosError mnerror
        cdef char* name = NULL
        self.print_banner('MINOS')
        if var is not None:
            name = var
            index = self.cfmin.userState().index(var)
            if self.cfmin.userState().minuitParameters()[i].isFixed():
                return None
            minos = new MnMinos(deref(self.pyfcn), deref(self.cfmin),strategy)
            mnerror = minos.minos(index,maxcall)
            self.merrors_struct[var]=minoserror2struct(mnerror)
            self.print_mnerror(var,self.mnerrors[var])
        else:
            for vname in self.varname:
                index = self.cfmin.userState().index(vname)
                if self.cfmin.userState().minuitParameters()[index].isFixed():
                    continue
                minos = new MnMinos(deref(self.pyfcn), deref(self.cfmin),strategy)
                mnerror = minos.minos(index,maxcall)
                self.merrors_struct[vname]=minoserror2struct(mnerror)
                self.print_mnerror(vname,self.mnerrors[vname])
        self.refreshInternalState()
        del minos
        return self.mnerrors


    def matrix(self, correlation=False, skip_fixed=False):
        pass

    def scan(self):
        raise NotImplementedError


    def contour(self):
        raise NotImplementedError

    #TODO: Modularize this
    #######Terminal Display Stuff######################
    #This is 2012 USE IPYTHON PEOPLE!!! :P
    def print_cfmin(self,tolerance):
        cdef MnUserParameterState ust = MnUserParameterState(self.cfmin.userState())
        ncalls = 0 if self.pyfcn is NULL else self.pyfcn.getNumCall()
        fmin = cfmin2struct(self.cfmin)
        print '*'*30
        self.print_cfmin_only(tolerance,ncalls)
        self.print_state(ust)
        print '*'*30


    def print_mnerror(self,vname,smnerr):
        stat = 'VALID' if smnerr.is_valid else 'PROBLEM'

        summary = 'Minos Status for %s: %s\n'%\
                (vname,stat)

        error = '| {:^15s} | {: >12g} | {: >12g} |\n'\
                .format('Error',smnerr.lower,smnerr.upper)
        valid = '| {:^15s} | {:^12s} | {:^12s} |\n'\
                .format('Valid',str(smnerr.lower_valid),str(smnerr.upper_valid))
        at_limit='| {:^15s} | {:^12s} | {:^12s} |\n'\
                .format('At Limit',str(smnerr.at_lower_limit),str(smnerr.at_upper_limit))
        max_fcn='| {:^15s} | {:^12s} | {:^12s} |\n'\
                .format('Max FCN',str(smnerr.at_lower_max_fcn),str(smnerr.at_upper_max_fcn))
        new_min='| {:^15s} | {:^12s} | {:^12s} |\n'\
                .format('New Min',str(smnerr.lower_new_min),str(smnerr.upper_new_min))
        hline = '-'*len(error)+'\n'
        print hline + summary +hline + error + valid + at_limit + max_fcn + new_min + hline


    cdef print_state(self,MnUserParameterState upst):
        cdef vector[MinuitParameter] mps = upst.minuitParameters()
        cdef int i
        vnames=list()
        values=list()
        errs=list()
        lim_minus = list()
        lim_plus = list()
        fixstate = list()
        for i in range(mps.size()):
            vnames.append(mps[i].name())
            values.append(mps[i].value())
            errs.append(mps[i].error())
            fixstate.append(mps[i].isFixed())
            lim_plus.append(mps[i].upperLimit() if mps[i].hasUpperLimit() else None)
            lim_minus.append(mps[i].lowerLimit() if mps[i].hasLowerLimit() else None)

        self.print_state_template(vnames, values, errs, lim_minus = lim_minus, lim_plus = lim_plus, fixstate = fixstate)


    def print_initial_state(self):
        raise NotImplementedError


    def print_cfmin_only(self,tolerance=None, ncalls = 0):
        fmin = cfmin2struct(self.cfmin)
        goaledm = 0.0001*tolerance*fmin.up if tolerance is not None else ''
        #despite what the doc said the code is actually 1e-4
        #http://wwwasdoc.web.cern.ch/wwwasdoc/hbook_html3/node125.html
        flatlocal = dict(locals().items()+fmin.__dict__.items())
        info1 = 'fval = %(fval)r | nfcn = %(nfcn)r | ncalls = %(ncalls)r\n'%flatlocal
        info2 = 'edm = %(edm)r (Goal: %(goaledm)r) | up = %(up)r\n'%flatlocal
        header1 = '|' + (' %14s |'*5)%('Valid','Valid Param','Accurate Covar','Posdef','Made Posdef')+'\n'
        hline = '-'*len(header1)+'\n'
        status1 = '|' + (' %14r |'*5)%(fmin.is_valid, fmin.has_valid_parameters,
                fmin.has_accurate_covar,fmin.has_posdef_covar,fmin.has_made_posdef_covar)+'\n'
        header2 = '|' + (' %14s |'*5)%('Hesse Fail','Has Cov','Above EDM','','Reach calllim')+'\n'
        status2 = '|' + (' %14r |'*5)%(fmin.hesse_failed, fmin.has_covariance,
                fmin.is_above_max_edm,'',fmin.has_reached_call_limit)+'\n'

        print hline + info1 + info2 +\
            hline + header1 + hline + status1 +\
            hline + header2 + hline+ status2 +\
            hline


    def print_state_template(self,vnames, values, errs, minos_minus=None, minos_plus=None,
            lim_minus=None, lim_plus=None, fixstate=None):
        #for anyone using terminal
        maxlength = max([len(x) for x in vnames])
        maxlength = max(5,maxlength)

        header = ('| {:^4s} | {:^%ds} | {:^8s} | {:^8s} | {:^8s} | {:^8s} | {:^8s} | {:^8s} | {:^8s} |\n'%maxlength).format(
                    '','Name', 'Value','Para Err', "Err-","Err+","Limit-","Limit+"," ")
        hline = '-'*len(header)+'\n'
        linefmt = '| {:>4d} | {:>%ds} = {:<8s} ± {:<8s} | {:<8s} | {:<8s} | {:<8s} | {:<8s} | {:^8s} |\n'%maxlength
        nfmt = '{:< 8.4G}'
        blank = ' '*8

        ret = hline+header+hline
        for i,v in enumerate(vnames):
            allnum = [i,v]
            for n in [values,errs,minos_minus,minos_plus,lim_minus,lim_plus]:
                if n is not None and n[i] is not None:
                    allnum+=[nfmt.format(n[i])]
                else:
                    allnum+=[blank]
            if fixstate is not None:
                allnum += ['FIXED' if fixstate[i] else ' ']
            else:
                allnum += ['']
            line = linefmt.format(*allnum)
            ret+=line
        ret+=hline
        print ret


    def print_banner(self, cmd):
        ret = '*'*50+'\n'
        ret += '*{:^48}*'.format(cmd)+'\n'
        ret += '*'*50+'\n'
        print ret


    def print_all_minos(self,cmd):
        for vname in varnames:
            if vname in self.merrors_struct:
                self.print_mnerror(vname,self.merrors_struct[vname])

    # def prepare(self, **kwds):
    #     self.tmin.SetFCN(self.fcn)
    #     self.fix_param = []
    #     self.free_param = []
    #     for i, varname in self.pos2var.items():
    #         initialvalue = kwds[varname] if varname in kwds else 0.
    #         initialstep = kwds['error_' + varname] if 'error_' + varname in kwds else 0.1
    #         lrange, urange = kwds['limit_' + varname] if 'limit_' + varname in kwds else (0., 0.)
    #         ierflg = self.tmin.DefineParameter(i, varname, initialvalue, initialstep, lrange, urange)
    #         assert(ierflg == 0)
    #         #now fix parameter
    #     for varname in self.varname:
    #         if 'fix_' + varname in kwds and kwds['fix_'+varname]:
    #             self.tmin.FixParameter(self.var2pos[varname])
    #             self.fix_param.append(varname)
    #         else:
    #             self.free_param.append(varname)


    def set_up(self, up):
        """set UP parameter 1 for chi^2 and 0.5 for log likelihood"""
        self.up = up


    # def set_printlevel(self, lvl):
    #     """
    #     set printlevel -1 quiet, 0 normal, 1 verbose
    #     """
    #     return self.tmin.SetPrintLevel(lvl)


    # def set_strategy(self, strategy):
    #     """
    #     set strategy
    #     """
    #     return self.tmin.Command('SET STR %d' % strategy)


    # def command(self, cmd):
    #     """execute a command"""
    #     return self.tmin.Command(cmd)



    # def migrad_ok(self):
    #     """check whether last migrad call result is OK"""
    #     return self.last_migrad_result == 0


    # def hesse(self):
    #     """run hesse"""
    #     self.tmin.SetFCN(self.fcn)
    #     self.tmin.mnhess()
    #     self.set_ave()


    # def minos(self, varname=None):
    #     """run minos"""
    #     self.tmin.SetFCN(self.fcn)
    #     if varname is None:
    #         self.tmin.mnmnos()
    #     else:
    #         val2pl = ROOT.Double(0.)
    #         val2pi = ROOT.Double(0.)
    #         pos = self.var2pos[varname] + 1
    #         self.tmin.mnmnot(pos, 0, val2pl, val2pi)
    #     self.set_ave()


    # def set_ave(self):
    #     """set args values and errors"""
    #     tmp_values = {}
    #     tmp_errors = {}
    #     for i, varname in self.pos2var.items():
    #         tmp_val = ROOT.Double(0.)
    #         tmp_err = ROOT.Double(0.)
    #         self.tmin.GetParameter(i, tmp_val, tmp_err)
    #         tmp_values[varname] = float(tmp_val)
    #         tmp_errors[varname] = float(tmp_err)
    #     self.values = tmp_values
    #     self.errors = tmp_errors

    #     val = self.values
    #     tmparg = []
    #     for arg in self.varname:
    #         tmparg.append(val[arg])
    #     self.args = tuple(tmparg)
    #     self.fitarg.update(self.values)
    #     for k, v in self.errors.items():
    #         self.fitarg['error_' + k] = v


    # def mnstat(self):
    #     """
    #     return named tuple of cfmin,fedm,errdef,npari,nparx,istat
    #     """
    #     cfmin = ROOT.Double(0.)
    #     fedm = ROOT.Double(0.)
    #     errdef = ROOT.Double(0.)
    #     npari = ROOT.Long(0.)
    #     nparx = ROOT.Long(0.)
    #     istat = ROOT.Long(0.)
    #     #void mnstat(Double_t& cfmin, Double_t& fedm, Double_t& errdef, Int_t& npari, Int_t& nparx, Int_t& istat)
    #     self.tmin.mnstat(cfmin, fedm, errdef, npari, nparx, istat)
    #     ret = Struct(cfmin=float(cfmin), fedm=float(fedm), ferrdef=float(errdef), npari=int(npari), nparx=int(nparx),
    #         istat=int(istat))
    #     return ret


    # def cfmin(self):
    #     return self.mnstat().cfmin


    # def matrix_accurate(self):
    #     """check whether error matrix is accurate"""
    #     if self.tmin.fLimset: print "Warning: some parameter are up against limit"
    #     return self.mnstat().istat == 3


    # def error_matrix(self, correlation=False):
    #     ndim = self.mnstat().npari
    #     #void mnemat(Double_t* emat, Int_t ndim)
    #     tmp = array('d', [0.] * (ndim * ndim))
    #     self.tmin.mnemat(tmp, ndim)
    #     ret = np.array(tmp)
    #     ret = ret.reshape((ndim, ndim))
    #     if correlation:
    #         diag = np.diagonal(ret)
    #         sigma_col = np.sqrt(diag[:, np.newaxis])
    #         sigma_row = sigma_col.T
    #         ret = ret / sigma_col / sigma_row
    #     return ret


    # def mnmatu(self):
    #     """print correlation coefficient"""
    #     return self.tmin.mnmatu(1)


    # def help(self, cmd):
    #     """print out help"""
    #     self.tmin.mnhelp(cmd)


    # def minos_errors(self):
    #     ret = {}
    #     self.tmin.SetFCN(self.fcn)
    #     for i, v in self.pos2var.items():
    #         eplus = ROOT.Double(0.)
    #         eminus = ROOT.Double(0.)
    #         eparab = ROOT.Double(0.)
    #         gcc = ROOT.Double(0.)
    #         self.tmin.mnerrs(i, eplus, eminus, eparab, gcc)
    #         #void mnerrs(Int_t number, Double_t& eplus, Double_t& eminus, Double_t& eparab, Double_t& gcc)
    #         ret[v] = Struct(eplus=float(eplus), eminus=float(eminus), eparab=float(eparab), gcc=float(gcc))
    #     return ret

    # def html_results(self):
    #     return MinuitHTMLResult(self)

    # def list_of_fixed_param(self):
    #     tmp_ret = list()#fortran index
    #     for i in range(self.tmin.GetNumFixedPars()):
    #         tmp_ret.append(self.tmin.fIpfix[i])
    #     #now get the constants
    #     for i in range(self.tmin.GetNumPars()):
    #         if self.tmin.fNvarl[i] == 0:
    #             tmp_ret.append(i+1)
    #     tmp_ret = list(set(tmp_ret))
    #     tmp_ret.sort()
    #     for i in range(len(tmp_ret)):
    #         tmp_ret[i]-=1 #convert to position
    #     ret = [self.pos2var[x] for x in tmp_ret]
    #     return ret

    # def list_of_vary_param(self):
    #     fix_pars = self.list_of_fixed_param()
    #     ret = [v for v in self.varname if v not in fix_pars]
    #     return ret

    # def html_error_matrix(self):
    #     return MinuitCorrelationMatrixHTML(self)
